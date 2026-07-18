import AppKit
import ItsytvCore

@Observable
@MainActor
final class AppIconLoader {
    private(set) var icons: [String: NSImage] = [:]
    private var pending: Set<String> = []

    func loadIcons(for apps: [(bundleID: String, name: String)]) {
        for app in apps {
            guard icons[app.bundleID] == nil, !pending.contains(app.bundleID) else { continue }
            guard AppIconFetcher.builtInSymbols[app.bundleID] == nil else { continue }
            pending.insert(app.bundleID)

            AppIconFetcher.fetchIconData(bundleID: app.bundleID, name: app.name) { [weak self] data in
                DispatchQueue.main.async {
                    defer { self?.pending.remove(app.bundleID) }
                    guard let data, let image = NSImage(data: data) else { return }
                    self?.icons[app.bundleID] = image
                }
            }
        }
    }
}
