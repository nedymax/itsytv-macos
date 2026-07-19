import AppKit
import ItsytvCore

@Observable
@MainActor
final class AppIconLoader {
    private(set) var icons: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var attempts: [String: Int] = [:]
    private let maximumAttempts = 2

    func loadIcons(for apps: [(bundleID: String, name: String)]) {
        for app in apps {
            guard icons[app.bundleID] == nil, !pending.contains(app.bundleID) else { continue }
            guard AppIconFetcher.builtInSymbols[app.bundleID] == nil else { continue }
            if let cached = Self.cachedImage(bundleID: app.bundleID) {
                icons[app.bundleID] = cached
                continue
            }
            loadIcon(for: app)
        }
    }

    private func loadIcon(for app: (bundleID: String, name: String)) {
        guard icons[app.bundleID] == nil, !pending.contains(app.bundleID) else { return }
        attempts[app.bundleID, default: 0] += 1
        let attempt = attempts[app.bundleID, default: 1]
        pending.insert(app.bundleID)

        AppIconFetcher.fetchIconData(bundleID: app.bundleID, name: app.name) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let image = NSImage(data: data) {
                    self.finish(app: app, data: data, image: image)
                    return
                }

                AppArtworkFallbackFetcher.fetchUSArtwork(bundleID: app.bundleID, name: app.name) { [weak self] data in
                    guard let self else { return }
                    if let data, let image = NSImage(data: data) {
                        self.finish(app: app, data: data, image: image)
                    } else {
                        self.pending.remove(app.bundleID)
                        guard attempt < self.maximumAttempts else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            self?.loadIcon(for: app)
                        }
                    }
                }
            }
        }
    }

    private func finish(app: (bundleID: String, name: String), data: Data, image: NSImage) {
        pending.remove(app.bundleID)
        attempts.removeValue(forKey: app.bundleID)
        icons[app.bundleID] = image
        let url = Self.cacheURL(bundleID: app.bundleID)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    static func cacheFileName(bundleID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return (bundleID.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString) + ".image"
    }

    private static func cacheURL(bundleID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.itsytv.app", isDirectory: true)
            .appendingPathComponent("AppArtwork", isDirectory: true)
            .appendingPathComponent(cacheFileName(bundleID: bundleID))
    }

    private static func cachedImage(bundleID: String) -> NSImage? {
        guard let data = try? Data(contentsOf: cacheURL(bundleID: bundleID)) else { return nil }
        return NSImage(data: data)
    }
}

private enum AppArtworkFallbackFetcher {
    static func fetchUSArtwork(bundleID: String, name: String, completion: @escaping (Data?) -> Void) {
        fetchLookup(bundleID: bundleID, name: name, entities: ["tvSoftware", "software"], completion: completion)
    }

    private static func fetchLookup(
        bundleID: String,
        name: String,
        entities: [String],
        completion: @escaping (Data?) -> Void
    ) {
        guard let entity = entities.first else {
            fetchSearch(name: name, completion: completion)
            return
        }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else {
            fetchLookup(bundleID: bundleID, name: name, entities: Array(entities.dropFirst()), completion: completion)
            return
        }

        fetchArtworkURL(from: url) { artworkURL in
            guard let artworkURL else {
                fetchLookup(bundleID: bundleID, name: name, entities: Array(entities.dropFirst()), completion: completion)
                return
            }
            download(from: artworkURL, completion: completion)
        }
    }

    private static func fetchSearch(name: String, completion: @escaping (Data?) -> Void) {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        fetchArtworkURL(from: url) { artworkURL in
            guard let artworkURL else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            download(from: artworkURL, completion: completion)
        }
    }

    private static func fetchArtworkURL(from url: URL, completion: @escaping (URL?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = (json["results"] as? [[String: Any]])?.first,
                  let value = result["artworkUrl512"] as? String ?? result["artworkUrl100"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(URL(string: value)) }
        }.resume()
    }

    private static func download(from url: URL, completion: @escaping (Data?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let validData: Data?
            if let response = response as? HTTPURLResponse,
               (200..<300).contains(response.statusCode),
               let data,
               NSImage(data: data) != nil {
                validData = data
            } else {
                validData = nil
            }
            DispatchQueue.main.async { completion(validData) }
        }.resume()
    }
}
