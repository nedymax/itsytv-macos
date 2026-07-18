import AppKit
import Carbon.HIToolbox

struct ShortcutKeys: Codable, Equatable {
    var modifiers: UInt
    var keyCode: UInt16

    var displayString: String {
        var result = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += keyCodeToString(keyCode)
        return result
    }

    var menuKeyEquivalent: String? {
        switch Int(keyCode) {
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Space: return " "
        case kVK_Delete: return "\u{7f}"
        case kVK_Escape: return "\u{1b}"
        case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: return keyCodeToCharacter(keyCode)?.lowercased()
        }
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask)
    }

    var isReservedMacShortcut: Bool {
        menuModifierFlags == .command && (keyCode == UInt16(kVK_ANSI_W) || keyCode == UInt16(kVK_ANSI_H))
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let char = keyCodeToCharacter(keyCode) {
                return char.uppercased()
            }
            return "?"
        }
    }

    private func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { bytes -> String? in
            guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                ptr,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

enum HotkeyRegistrationError: LocalizedError, Equatable {
    case invalidDeviceID
    case reservedMacShortcut
    case registrationFailed(OSStatus)
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .invalidDeviceID:
            return "Select a valid Apple TV before assigning a shortcut."
        case .reservedMacShortcut:
            return "⌘W and ⌘H keep their standard macOS behavior and cannot be assigned."
        case .registrationFailed(let status):
            return "macOS could not register this shortcut (error \(status)). It may already be in use."
        case .storageFailed:
            return "The shortcut could not be saved."
        }
    }
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeys: [UInt32: (id: EventHotKeyID, ref: EventHotKeyRef?, deviceID: String)] = [:]
    private var nextId: UInt32 = 1
    var onHotkeyPressed: ((String) -> Void)?
    private(set) var registrationFailures: [String: HotkeyRegistrationError] = [:]

    private init() {
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                HotkeyManager.shared.handleHotkey(id: hotkeyID.id)
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    private func handleHotkey(id: UInt32) {
        guard let entry = hotkeys[id] else { return }
        DispatchQueue.main.async {
            self.onHotkeyPressed?(entry.deviceID)
        }
    }

    @discardableResult
    func register(deviceID: String, keys: ShortcutKeys) -> Result<Void, HotkeyRegistrationError> {
        guard HotkeyStorage.isValidDeviceID(deviceID) else {
            registrationFailures[deviceID] = .invalidDeviceID
            return .failure(.invalidDeviceID)
        }
        guard !keys.isReservedMacShortcut else {
            registrationFailures[deviceID] = .reservedMacShortcut
            return .failure(.reservedMacShortcut)
        }

        let id = nextId
        nextId += 1

        let hotkeyID = EventHotKeyID(signature: OSType(0x4954_5359), id: id) // "ITSY"
        var hotkeyRef: EventHotKeyRef?

        let modifiers = carbonModifiers(from: NSEvent.ModifierFlags(rawValue: keys.modifiers))

        let status = RegisterEventHotKey(
            UInt32(keys.keyCode),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            hotkeys[id] = (hotkeyID, hotkeyRef, deviceID)
            registrationFailures.removeValue(forKey: deviceID)
            return .success(())
        }
        let error = HotkeyRegistrationError.registrationFailed(status)
        registrationFailures[deviceID] = error
        return .failure(error)
    }

    func unregister(deviceID: String) {
        registrationFailures.removeValue(forKey: deviceID)
        let matchingIDs = hotkeys.compactMap { id, entry in entry.deviceID == deviceID ? id : nil }
        for id in matchingIDs {
            guard let entry = hotkeys.removeValue(forKey: id) else { continue }
            if let ref = entry.ref {
                UnregisterEventHotKey(ref)
            }
        }
    }

    func unregisterAll() {
        for entry in hotkeys.values {
            if let ref = entry.ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotkeys.removeAll()
        registrationFailures.removeAll()
        nextId = 1
    }

    func reregisterAll() {
        unregisterAll()

        // Re-register from storage
        for (deviceID, keys) in HotkeyStorage.loadAll() {
            _ = register(deviceID: deviceID, keys: keys)
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

enum HotkeyStorage {
    private static let storageKey = "deviceHotkeys"

    @discardableResult
    static func save(deviceID: String, keys: ShortcutKeys?) -> Result<Void, HotkeyRegistrationError> {
        guard isValidDeviceID(deviceID) else {
            return .failure(.invalidDeviceID)
        }

        var all = loadAll()
        let previous = all[deviceID]

        if let keys {
            HotkeyManager.shared.unregister(deviceID: deviceID)
            switch HotkeyManager.shared.register(deviceID: deviceID, keys: keys) {
            case .success:
                break
            case .failure(let error):
                if let previous {
                    _ = HotkeyManager.shared.register(deviceID: deviceID, keys: previous)
                }
                return .failure(error)
            }
            all[deviceID] = keys
        } else {
            HotkeyManager.shared.unregister(deviceID: deviceID)
            all.removeValue(forKey: deviceID)
        }

        guard let data = try? JSONEncoder().encode(all) else {
            HotkeyManager.shared.unregister(deviceID: deviceID)
            if let previous {
                _ = HotkeyManager.shared.register(deviceID: deviceID, keys: previous)
            }
            return .failure(.storageFailed)
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        return .success(())
    }

    static func load(deviceID: String) -> ShortcutKeys? {
        loadAll()[deviceID]
    }

    static func loadAll() -> [String: ShortcutKeys] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let all = try? JSONDecoder().decode([String: ShortcutKeys].self, from: data) else {
            return [:]
        }
        return all.filter { isValidDeviceID($0.key) }
    }

    static func isValidDeviceID(_ deviceID: String) -> Bool {
        !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
