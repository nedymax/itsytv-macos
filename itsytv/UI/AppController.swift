import AppKit
import SwiftUI
import Combine
import ServiceManagement
import os.log
import ItsytvCore

private let log = Logger(subsystem: "com.itsytv.app", category: "Panel")

@MainActor
final class AppController: NSObject, NSMenuDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private let manager: AppleTVManager
    private let iconLoader: AppIconLoader
    private var observation: AnyCancellable?
    private var panel: NSPanel?
    private var panelDeviceID: String?
    private var keyboardMonitor: Any?
    private var alwaysOnTopObserver: NSObjectProtocol?
    private var lastAlwaysOnTopValue: Bool?
    private var pendingOpenTimeoutWorkItem: DispatchWorkItem?

    init(manager: AppleTVManager, iconLoader: AppIconLoader) {
        self.manager = manager
        self.iconLoader = iconLoader
        super.init()
        setupStatusItem()
        rebuildMenu()
        startObserving()
        setupHotkeyHandler()
        manager.startScanning()
    }

    func cleanup() {
        removeKeyboardMonitor()
        if let observer = alwaysOnTopObserver {
            NotificationCenter.default.removeObserver(observer)
            alwaysOnTopObserver = nil
        }
        observation?.cancel()
        observation = nil
        pendingOpenTimeoutWorkItem?.cancel()
        pendingOpenTimeoutWorkItem = nil
        HotkeyManager.shared.unregisterAll()
        panel?.close()
        panel = nil
        panelDeviceID = nil
    }

    private func setupHotkeyHandler() {
        HotkeyManager.shared.reregisterAll()
        HotkeyManager.shared.onHotkeyPressed = { [weak self] deviceID in
            guard let self else { return }
            if self.panel?.isVisible == true && self.panelDeviceID == deviceID {
                self.manager.disconnect()
            } else {
                self.openRemote(for: deviceID)
            }
        }
    }

    private var pendingOpenDeviceID: String?

    func openRemote(for deviceID: String? = nil) {
        let targetID: String?
        if let deviceID {
            targetID = deviceID
        } else {
            // Pick the first discovered device that has stored credentials
            targetID = manager.discoveredDevices.first(where: { KeychainStorage.load(for: $0.id) != nil })?.id
        }
        let discoveredCount = manager.discoveredDevices.count
        log.error("openRemote: targetID=\(targetID ?? "nil", privacy: .public) discoveredCount=\(discoveredCount, privacy: .public)")
        guard let targetID else {
            log.error("openRemote: no targetID, returning")
            return
        }

        if let device = manager.discoveredDevices.first(where: { $0.id == targetID }) {
            log.error("openRemote: device found, connecting")
            pendingOpenTimeoutWorkItem?.cancel()
            pendingOpenTimeoutWorkItem = nil
            connectAndShow(device)
        } else {
            log.error("openRemote: device not discovered yet, setting pendingOpenDeviceID")
            pendingOpenDeviceID = targetID
            pendingOpenTimeoutWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.pendingOpenDeviceID == targetID else { return }
                self?.pendingOpenDeviceID = nil
                log.warning("openRemote: timed out waiting for device \(targetID, privacy: .public)")
            }
            pendingOpenTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
        }
    }

    private func connectAndShow(_ device: AppleTVDevice) {
        manager.connect(to: device)
        if KeychainStorage.load(for: device.id) != nil {
            showPanel()
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            if let icon = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: "ItsyTV")
                ?? NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: "ItsyTV")
                ?? NSImage(systemSymbolName: "appletv.fill", accessibilityDescription: "ItsyTV") {
                icon.isTemplate = true
                button.image = icon.withSymbolConfiguration(configuration)
            }
            // Handle clicks ourselves instead of attaching the menu permanently:
            // a left-click while the remote is closed jumps straight to the last
            // device; right-click (or any click with the remote open) shows the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        // Remote closed + a reachable, paired last device → open it directly.
        // Everything else (remote open, right-click, no/unreachable last device)
        // falls back to the dropdown, as before.
        if !wantsMenu,
           panel?.isVisible != true,
           case .disconnected = manager.connectionStatus,
           let lastID = manager.lastConnectedDeviceID,
           KeychainStorage.load(for: lastID) != nil,
           manager.discoveredDevices.contains(where: { $0.id == lastID }) {
            openRemote(for: lastID)
        } else {
            showMenu()
        }
    }

    /// Pop the status menu by temporarily attaching it, then detach on close
    /// (see `menuDidClose`) so the next click routes back to `statusItemClicked`.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    private func startObserving() {
        observation = Timer.publish(every: 0.3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.handleStateChange()
            }
    }

    private var lastKnownStatus: ConnectionStatus = .disconnected
    private var lastKnownDeviceCount: Int = 0
    private var hasPairedDevice: Bool {
        manager.discoveredDevices.contains { KeychainStorage.load(for: $0.id) != nil }
    }

    private func handleStateChange() {
        let currentStatus = manager.connectionStatus
        let currentDeviceCount = manager.discoveredDevices.count

        // Fulfill pending openRemote when the target device is discovered
        if let pendingID = pendingOpenDeviceID,
           let device = manager.discoveredDevices.first(where: { $0.id == pendingID }) {
            pendingOpenDeviceID = nil
            pendingOpenTimeoutWorkItem?.cancel()
            pendingOpenTimeoutWorkItem = nil
            connectAndShow(device)
            return
        }

        guard currentStatus != lastKnownStatus || currentDeviceCount != lastKnownDeviceCount else { return }
        lastKnownStatus = currentStatus
        lastKnownDeviceCount = currentDeviceCount

        switch currentStatus {
        case .disconnected:
            dismissPanel()
            rebuildMenu()
        case .connecting:
            if panel != nil {
                // Panel already open — SwiftUI will update content
            } else {
                rebuildMenu()
            }
        case .pairing, .error:
            rebuildMenu()
        case .connected:
            menu.cancelTracking()
            showPanel()
        }
    }

    private var shouldShowItsyhomePromo: Bool {
        let hasDevices = hasPairedDevice
        let isInstalled: Bool = {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.nickustinov.itsyhome") else {
                return false
            }
            let path = url.path
            return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        }()
        return hasDevices && !isInstalled
    }

    // MARK: - Menu building

    private func rebuildMenu() {
        menu.removeAllItems()

        switch manager.connectionStatus {
        case .disconnected:
            buildDeviceList()
        case .connecting:
            if panel != nil { return }
            let item = NSMenuItem(title: "Connecting...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .pairing:
            let pairing = PairingMenuItem(manager: manager)
            menu.addItem(pairing)
        case .error(let message):
            let errorItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
            let dismissItem = createActionItem(title: "Dismiss") { [weak self] in
                self?.manager.disconnect()
            }
            menu.addItem(dismissItem)
        case .connected:
            buildDeviceList()
        }

        switch manager.connectionStatus {
        case .pairing, .connecting:
            break
        default:
            menu.addItem(NSMenuItem.separator())
            #if !APPSTORE
            if shouldShowItsyhomePromo {
                menu.addItem(createItsyhomePromoItem())
                menu.addItem(NSMenuItem.separator())
            }
            #endif
            let loginItem = createCheckboxItem(
                title: "Launch at login",
                isOn: SMAppService.mainApp.status == .enabled
            ) {
                do {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    } else {
                        try SMAppService.mainApp.register()
                    }
                } catch {
                    log.error("Failed to toggle login item: \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "Could not update Launch at Login"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
            menu.addItem(loginItem)
            #if !APPSTORE
            let updateItem = createActionItem(title: "Check for updates...", symbolName: "arrow.triangle.2.circlepath") {
                UpdateChecker.check()
            }
            menu.addItem(updateItem)
            #endif
            let quitItem = createActionItem(title: "Quit", symbolName: "power") {
                NSApplication.shared.terminate(nil)
            }
            menu.addItem(quitItem)
        }
    }

    private func buildDeviceList() {
        if manager.discoveredDevices.isEmpty {
            let scanning = NSMenuItem(title: "Scanning for devices...", action: nil, keyEquivalent: "")
            scanning.isEnabled = false
            menu.addItem(scanning)
        } else {
            let sorted = manager.discoveredDevices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for device in sorted {
                let isPaired = KeychainStorage.load(for: device.id) != nil
                let item = createDeviceItem(device: device, isPaired: isPaired)
                menu.addItem(item)
            }
        }
    }

    private func createDeviceItem(device: AppleTVDevice, isPaired: Bool) -> NSMenuItem {
        if !isPaired {
            return createUnpairedDeviceItem(device)
        }

        let item = ClosureMenuItem(title: device.name) { [weak self] in
            self?.openRemote(for: device.id)
        }
        let symbol = NSImage(systemSymbolName: "appletv.fill", accessibilityDescription: device.name)
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
        item.image = symbol?.withSymbolConfiguration(configuration)
        item.image?.isTemplate = false

        if let keys = HotkeyStorage.load(deviceID: device.id) {
            if let registrationError = HotkeyManager.shared.registrationFailures[device.id] {
                let title = NSMutableAttributedString(string: device.name)
                title.append(NSAttributedString(
                    string: "  Shortcut inactive",
                    attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 11)]
                ))
                item.attributedTitle = title
                item.toolTip = registrationError.localizedDescription
            } else if let keyEquivalent = keys.menuKeyEquivalent {
                item.keyEquivalent = keyEquivalent
                item.keyEquivalentModifierMask = keys.menuModifierFlags
            }
        }
        return item
    }

    private func createUnpairedDeviceItem(_ device: AppleTVDevice) -> NSMenuItem {
        let view = PersistentMenuItemView(frame: NSRect(
            x: 0,
            y: 0,
            width: DS.ControlSize.menuItemWidth,
            height: DS.ControlSize.menuItemHeight
        ))
        view.setAccessibilityLabel(device.name)
        view.setAccessibilityRole(.button)

        let iconSize = DS.ControlSize.iconMedium
        let icon = NSImageView(frame: NSRect(
            x: DS.Spacing.md,
            y: (view.bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        ))
        icon.image = NSImage(systemSymbolName: "appletv.fill", accessibilityDescription: device.name)
        icon.contentTintColor = .secondaryLabelColor
        view.addSubview(icon)

        let label = NSTextField(labelWithString: device.name)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: DS.Spacing.md + iconSize + DS.Spacing.sm,
            y: (view.bounds.height - 17) / 2,
            width: view.bounds.width - DS.Spacing.md * 2 - iconSize - DS.Spacing.sm,
            height: 17
        )
        view.addSubview(label)
        view.onAction = { [weak self] in self?.openRemote(for: device.id) }

        let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
        item.view = view
        return item
    }

    private func createActionItem(title: String, symbolName: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let symbolName {
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        }
        return item
    }

    private func createCheckboxItem(title: String, isOn: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.state = isOn ? .on : .off
        return item
    }

    private func createItsyhomePromoItem() -> NSMenuItem {
        let item = ClosureMenuItem(title: "Try Itsyhome", action: {
            if let url = URL(string: "macappstore://apps.apple.com/app/itsyhome/id6758070650") {
                NSWorkspace.shared.open(url)
            }
        })
        item.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Try Itsyhome")
        return item
    }

    // MARK: - Panel

    private func showPanel() {
        if panel != nil {
            return
        }

        let panelContent = PanelContentView()
            .environment(manager)
            .environment(iconLoader)

        let hostingView = NSHostingView(rootView: panelContent)
        hostingView.safeAreaRegions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let surface = makePanelSurface(hostingView: hostingView)

        let alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 176, height: 400),
            styleMask: alwaysOnTop ? [.nonactivatingPanel] : [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = surface
        panel.isFloatingPanel = alwaysOnTop
        lastAlwaysOnTopValue = alwaysOnTop
        panel.level = alwaysOnTop ? .statusBar : .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.hasShadow = true

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Position after makeKeyAndOrderFront — AppKit constrains the
        // frame during ordering for .statusBar level panels, so we must
        // set the origin after the window is on screen.
        if let origin = PanelPositioning.resolvedOrigin(
            savedOrigin: savedPanelOrigin(panelHeight: panel.frame.height),
            panelSize: panel.frame.size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            statusItemFrame: statusItem.button?.window?.frame
        ) {
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
        self.panelDeviceID = manager.connectedDeviceID
        installKeyboardMonitor()

        // Observe "Always on top" toggle changes while panel is open
        alwaysOnTopObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            let onTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
            guard onTop != self.lastAlwaysOnTopValue else { return }
            self.lastAlwaysOnTopValue = onTop
            panel.isFloatingPanel = onTop
            panel.level = onTop ? .statusBar : .normal
            panel.styleMask = onTop ? [.nonactivatingPanel] : [.borderless]
            panel.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanelSurface(hostingView: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            hostingView.frame = NSRect(x: 0, y: 0, width: 176, height: 400)
            hostingView.autoresizingMask = [.width, .height]
            let glass = NSGlassEffectView(frame: hostingView.frame)
            glass.style = .regular
            glass.cornerRadius = 10
            glass.contentView = hostingView
            return glass
        }
        #endif

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let vibrancy = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 176, height: 400))
        vibrancy.material = .menu
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = 10
        vibrancy.layer?.masksToBounds = true
        vibrancy.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: vibrancy.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: vibrancy.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: vibrancy.trailingAnchor),
        ])
        return vibrancy
    }

    private func dismissPanel() {
        removeKeyboardMonitor()
        if let observer = alwaysOnTopObserver {
            NotificationCenter.default.removeObserver(observer)
            alwaysOnTopObserver = nil
        }
        savePanelPosition()
        panel?.close()
        panel = nil
        panelDeviceID = nil
        lastAlwaysOnTopValue = nil
    }

    private func savePanelPosition() {
        guard let frame = panel?.frame else {
            log.debug("save: no panel frame")
            return
        }
        guard let deviceID = panelDeviceID else {
            log.debug("save: no panelDeviceID")
            return
        }
        // Save top-left corner (x, maxY) — the visual anchor point.
        // AppKit origin is bottom-left, but top-left stays stable
        // regardless of panel height changes from SwiftUI layout.
        let dict: [String: CGFloat] = ["x": frame.minX, "topY": frame.maxY]
        UserDefaults.standard.set(dict, forKey: "panelOrigin_\(deviceID)")
        log.info("save: topLeft (\(frame.minX), \(frame.maxY)) for device \(deviceID)")
    }

    private func savedPanelOrigin(panelHeight: CGFloat) -> NSPoint? {
        guard let deviceID = manager.connectedDeviceID else {
            log.debug("restore: no connectedDeviceID")
            return nil
        }
        let key = "panelOrigin_\(deviceID)"
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else {
            log.debug("restore: no saved value for key \(key)")
            return nil
        }
        guard let x = dict["x"] as? CGFloat, let topY = dict["topY"] as? CGFloat else {
            log.debug("restore: bad dict format: \(dict)")
            return nil
        }
        // Convert top-left back to AppKit bottom-left origin
        let origin = NSPoint(x: x, y: topY - panelHeight)
        log.info("restore: topLeft (\(x), \(topY)) → origin (\(origin.x), \(origin.y)) for device \(deviceID)")
        return origin
    }

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel,
                  PanelKeyboardRouting.shouldHandle(
                    panelIsVisible: panel.isVisible,
                    panelIsKey: panel.isKeyWindow,
                    panelIsApplicationKeyWindow: NSApp.keyWindow === panel,
                    eventTargetsPanel: event.window === panel
                  ) else { return event }
            if self.handleRemoteKeyDown(event) { return nil }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    private func handleRemoteKeyDown(_ event: NSEvent) -> Bool {
        // Cmd shortcuts work even when text input is focused
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 40: // Cmd+K
                manager.keyboardToggleCounter &+= 1
                manager.triggerKeyboardBlink(.siri)
                return true
            case 3: // Cmd+F
                let key = "showAppsSearch"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                return true
            default:
                break
            }
        }

        // Cmd+Shift shortcuts
        if event.modifierFlags.contains([.command, .shift]) {
            switch event.keyCode {
            case 46: // Cmd+Shift+M
                manager.toggleMute()
                manager.triggerKeyboardBlink(.siri)
                return true
            default:
                break
            }
        }

        // Ignore when any text input is focused (field editor, NSTextField, or SwiftUI text)
        if let responder = panel?.firstResponder {
            var r: NSResponder? = responder
            while let current = r {
                if current is NSText || current is NSTextField { return false }
                r = current.nextResponder
            }
        }

        let button: CompanionButton? = switch event.keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36:  .select
        case 51:  .home
        case 53:  .menu
        case 49:  .playPause
        case 24:  .volumeUp
        case 27:  .volumeDown
        default:  nil
        }
        guard let button else { return false }
        manager.pressButton(button)
        manager.triggerKeyboardBlink(button)
        return true
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        manager.refreshScanning()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next status-item click routes to `statusItemClicked`
        // rather than re-opening the menu automatically.
        statusItem.menu = nil
    }
}

// MARK: - Panel SwiftUI content

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() {
        handler()
    }
}

/// Used only for unpaired devices because native menu-item actions close the
/// menu before the inline pairing flow can replace it.
private final class PersistentMenuItemView: NSView {
    var onAction: (() -> Void)?
    private var isHighlighted = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        updateContentColors(highlighted: true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        updateContentColors(highlighted: false)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAction?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    private func updateContentColors(highlighted: Bool) {
        for subview in subviews {
            (subview as? NSTextField)?.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
            (subview as? NSImageView)?.contentTintColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        }
    }
}

// MARK: - Key-capable panel

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w":
            performClose(nil)
            return true
        case "h":
            NSApp.hide(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct PanelMenuButton: View {
    let deviceID: String
    let onUnpair: () -> Void
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("showAppsSearch") private var showAppsSearch = false
    @State private var showingHotkeyRecorder = false
    @State private var currentHotkey: ShortcutKeys?

    var body: some View {
        Menu {
            Toggle("Always on top", isOn: $alwaysOnTop)
            Toggle("Show app search", isOn: $showAppsSearch)
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button(hotkeyButtonTitle) {
                showingHotkeyRecorder = true
            }
            .disabled(deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if currentHotkey != nil {
                Button("Remove hotkey", role: .destructive) {
                    HotkeyStorage.save(deviceID: deviceID, keys: nil)
                    currentHotkey = nil
                }
            }
            Divider()
            Button("Unpair", role: .destructive, action: onUnpair)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Remote options")
        .accessibilityLabel("Remote options")
        .popover(isPresented: $showingHotkeyRecorder) {
            ShortcutRecorderView(deviceID: deviceID) { keys in
                currentHotkey = keys
                showingHotkeyRecorder = false
            }
        }
        .onAppear {
            currentHotkey = HotkeyStorage.load(deviceID: deviceID)
        }
    }

    private var hotkeyButtonTitle: String {
        if let keys = currentHotkey {
            return "Change hotkey (\(keys.displayString))"
        }
        return "Assign hotkey..."
    }
}

struct ShortcutRecorderView: View {
    let deviceID: String
    let onRecorded: (ShortcutKeys?) -> Void
    @State private var isRecording = false
    @State private var recordedKeys: ShortcutKeys?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Text(displayText)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(isRecording && recordedKeys == nil ? .secondary : .primary)
                .frame(minWidth: 100, minHeight: 30)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(8)

            Text("Use ⌘, ⌥, ⌃, ⇧ with a key")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Shortcut error: \(errorMessage)")
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onRecorded(HotkeyStorage.load(deviceID: deviceID))
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    if let keys = recordedKeys {
                        switch HotkeyStorage.save(deviceID: deviceID, keys: keys) {
                        case .success:
                            errorMessage = nil
                            onRecorded(keys)
                        case .failure(let error):
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recordedKeys == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 220, idealWidth: 240)
        .background(ShortcutRecorderHelper(isRecording: $isRecording, recordedKeys: $recordedKeys))
        .onAppear {
            isRecording = true
            recordedKeys = HotkeyStorage.load(deviceID: deviceID)
        }
        .onDisappear {
            isRecording = false
        }
    }

    private var displayText: String {
        if let keys = recordedKeys {
            return keys.displayString
        }
        return isRecording ? "Press keys..." : "None"
    }
}

struct ShortcutRecorderHelper: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var recordedKeys: ShortcutKeys?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcutRecorded = { keys in
            recordedKeys = keys
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.isRecording = isRecording
    }
}

final class ShortcutRecorderNSView: NSView {
    var isRecording = false
    var onShortcutRecorded: ((ShortcutKeys) -> Void)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupMonitor()
        } else {
            removeMonitor()
        }
    }

    private func setupMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording, let window = self.window,
                  window.isKeyWindow, NSApp.keyWindow === window, event.window === window else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Require at least one modifier
            guard !modifiers.isEmpty else { return event }

            // Ignore if only modifier keys pressed (no actual key)
            let keyCode = event.keyCode
            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63] // Cmd, Shift, Option, Ctrl variants
            if modifierKeyCodes.contains(keyCode) { return event }

            let keys = ShortcutKeys(modifiers: modifiers.rawValue, keyCode: keyCode)
            DispatchQueue.main.async {
                self.onShortcutRecorded?(keys)
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        removeMonitor()
    }
}

struct PanelCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Close remote")
        .accessibilityLabel("Close remote")
    }
}

struct PanelContentView: View {
    @Environment(AppleTVManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            switch manager.connectionStatus {
            case .connecting, .connected:
                RemoteControlView()
            case .error(let message):
                ErrorView(message: message)
            default:
                EmptyView()
            }
        }
        .frame(width: 176)
    }
}

// MARK: - NSWindowDelegate

extension AppController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel {
            savePanelPosition()
            if manager.connectionStatus != .disconnected {
                manager.disconnect()
            }
            panel = nil
            panelDeviceID = nil
        }
    }
}

// MARK: - Pairing menu item

final class PairingMenuItem: NSMenuItem {

    private let manager: AppleTVManager
    private var digits: [Int?] = [nil, nil, nil, nil]
    private var digitLabels: [NSTextField] = []
    private var digitBoxes: [NSView] = []
    private weak var containerView: PairingContainerView?

    init(manager: AppleTVManager) {
        self.manager = manager
        super.init(title: "Pairing", action: nil, keyEquivalent: "")
        self.view = buildView()
    }

    required init(coder: NSCoder) {
        fatalError()
    }

    private var currentIndex: Int {
        digits.firstIndex(where: { $0 == nil }) ?? 4
    }

    private func buildView() -> NSView {
        let width = DS.ControlSize.menuItemWidth
        let padding = DS.Spacing.lg

        // Layout
        let digitBoxSize: CGFloat = 44
        let digitBoxSpacing: CGFloat = DS.Spacing.sm
        let allDigitsWidth = digitBoxSize * 4 + digitBoxSpacing * 3
        let titleHeight: CGFloat = 17
        let closeButtonSize: CGFloat = 20
        let topPadding = DS.Spacing.md
        let afterTitle = DS.Spacing.md
        let bottomPadding = DS.Spacing.lg

        let totalHeight = topPadding + titleHeight + afterTitle + digitBoxSize + bottomPadding

        let container = PairingContainerView(
            frame: NSRect(x: 0, y: 0, width: width, height: totalHeight),
            onDigit: { [weak self] digit in self?.enterDigit(digit) },
            onBackspace: { [weak self] in self?.backspace() },
            onCancel: { [weak self] in self?.manager.disconnect() }
        )
        containerView = container

        // Title
        let titleY = totalHeight - topPadding - titleHeight
        let title = NSTextField(labelWithString: "Enter PIN from your Apple TV")
        title.frame = NSRect(x: padding, y: titleY, width: width - padding * 2 - closeButtonSize - DS.Spacing.sm, height: titleHeight)
        title.font = DS.Typography.labelMedium
        title.textColor = DS.Colors.foreground
        container.addSubview(title)

        // Close (X) button — top right
        let closeX = width - padding - closeButtonSize
        let closeY = titleY + (titleHeight - closeButtonSize) / 2
        let closeButton = CloseButton(frame: NSRect(x: closeX, y: closeY, width: closeButtonSize, height: closeButtonSize))
        closeButton.onPress = { [weak self] in
            self?.manager.disconnect()
        }
        container.addSubview(closeButton)

        // Digit boxes — centered
        let digitsY = titleY - afterTitle - digitBoxSize
        let digitsX = (width - allDigitsWidth) / 2
        let digitBoxBg = NSColor.controlBackgroundColor
        let digitBoxBorder = NSColor.separatorColor
        let digitBoxFocusBorder = NSColor.keyboardFocusIndicatorColor

        for i in 0..<4 {
            let boxX = digitsX + CGFloat(i) * (digitBoxSize + digitBoxSpacing)
            let box = DigitBoxView(frame: NSRect(x: boxX, y: digitsY, width: digitBoxSize, height: digitBoxSize))
            box.bgColor = digitBoxBg
            box.borderColor = digitBoxBorder
            box.focusBorderColor = digitBoxFocusBorder
            container.addSubview(box)
            digitBoxes.append(box)

            let labelHeight: CGFloat = 22
            let labelY = (digitBoxSize - labelHeight) / 2
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 0, y: labelY, width: digitBoxSize, height: labelHeight)
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
            label.textColor = DS.Colors.foreground
            label.alignment = .center
            box.addSubview(label)
            digitLabels.append(label)
        }

        updateDigitDisplay()
        return container
    }

    func enterDigit(_ digit: Int) {
        guard currentIndex < 4 else { return }
        digits[currentIndex] = digit
        updateDigitDisplay()
        if currentIndex == 4 {
            let pin = digits.compactMap { $0 }.map(String.init).joined()
            manager.submitPIN(pin)
        }
    }

    func backspace() {
        let idx = currentIndex - 1
        guard idx >= 0 else { return }
        digits[idx] = nil
        updateDigitDisplay()
    }

    private func updateDigitDisplay() {
        for (i, label) in digitLabels.enumerated() {
            label.stringValue = digits[i].map(String.init) ?? ""
        }
        for (i, box) in digitBoxes.enumerated() {
            if let digitBox = box as? DigitBoxView {
                digitBox.isFocused = i == currentIndex
                digitBox.needsDisplay = true
            }
        }
    }
}

// MARK: - Digit box

private final class DigitBoxView: NSView {

    var bgColor: NSColor = .gray
    var borderColor: NSColor = .darkGray
    var focusBorderColor: NSColor = .black
    var isFocused = false

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: DS.Radius.md, yRadius: DS.Radius.md)
        path.fill()

        let strokeColor = isFocused ? focusBorderColor : borderColor
        strokeColor.setStroke()
        let strokePath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: DS.Radius.md, yRadius: DS.Radius.md)
        strokePath.lineWidth = 2
        strokePath.stroke()
    }
}

// MARK: - Pairing container (captures keyboard)

private final class PairingContainerView: NSView {

    var onDigit: ((Int) -> Void)?
    var onBackspace: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, onDigit: @escaping (Int) -> Void, onBackspace: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onDigit = onDigit
        self.onBackspace = onBackspace
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            enclosingMenuItem?.menu?.cancelTracking()
            onCancel?()
            return
        }
        guard let chars = event.characters else { return }
        for ch in chars {
            if let digit = ch.wholeNumberValue {
                onDigit?(digit)
            } else if ch == "\u{7F}" || ch == "\u{08}" {
                onBackspace?()
            }
        }
    }
}

// MARK: - Pairing close button

private final class CloseButton: NSButton {
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel pairing")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = "Cancel pairing"
        setAccessibilityLabel("Cancel pairing")
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func invoke() {
        enclosingMenuItem?.menu?.cancelTracking()
        onPress?()
    }
}
