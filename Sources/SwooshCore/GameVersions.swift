import Foundation

public struct InstalledGameVersion: Equatable, Codable, Sendable {
    public let titleID: String
    public let contentVersion: UInt32
    public let displayVersion: String?
    public var label: String { displayVersion.map { "v" + $0 } ?? "Revision \(contentVersion)" }

    public init(titleID: String, contentVersion: UInt32, displayVersion: String? = nil) {
        self.titleID = titleID.uppercased(); self.contentVersion = contentVersion
        self.displayVersion = displayVersion
    }

    public static func validTitleID(_ value: String) -> Bool {
        value.count == 16 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    /// Read only explicit package/build rows. Profile comments and macOS bundle versions
    /// can describe different releases and must not be treated as the installed game version.
    public static func profile(_ text: String) -> InstalledGameVersion? {
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
        let titles = rows.filter { $0.first == "title_id" }.compactMap { $0.count == 2 ? $0[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        let packages = rows.filter { $0.first == "package" }.compactMap { $0.count == 2 ? $0[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        guard titles.count == 1, validTitleID(titles[0]), packages.count == 1, packages[0].hasPrefix("v"),
              let revision = UInt32(packages[0].dropFirst()) else { return nil }
        let builds = rows.filter { $0.first == "build" && $0.count >= 3 && $0[1] == packages[0] }
        guard builds.count == 1 else { return nil }
        let version = builds[0][2].trimmingCharacters(in: .whitespacesAndNewlines)
        return InstalledGameVersion(titleID: titles[0], contentVersion: revision, displayVersion: version.isEmpty ? nil : version)
    }

    public static func read(beside app: URL, libraryRoot: URL) -> InstalledGameVersion? {
        let parent = app.deletingLastPathComponent()
        // A manifest shared by the library root must not describe every root-level app.
        if parent.standardizedFileURL != libraryRoot.standardizedFileURL {
            let manifest = parent.appendingPathComponent("SwooshGame.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                guard let data = try? Data(contentsOf: manifest), data.count <= 65536,
                      let value = try? JSONDecoder().decode(InstalledGameVersion.self, from: data), validTitleID(value.titleID) else { return nil }
                return InstalledGameVersion(titleID: value.titleID, contentVersion: value.contentVersion, displayVersion: value.displayVersion)
            }
        }
        var roots = [app.appendingPathComponent("Contents/Resources/GameData/profile")]
        if parent.standardizedFileURL != libraryRoot.standardizedFileURL { roots.append(parent.appendingPathComponent("GameData/profile")) }
        var versions: [InstalledGameVersion] = []
        for root in roots {
            for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                guard validTitleID(folder.lastPathComponent), let data = try? Data(contentsOf: folder.appendingPathComponent("game.tsv")), data.count <= 1_000_000,
                      let text = String(data: data, encoding: .utf8), let value = profile(text), value.titleID == folder.lastPathComponent.uppercased() else { continue }
                if !versions.contains(value) { versions.append(value) }
            }
        }
        return versions.count == 1 ? versions[0] : nil
    }
}

public struct GameRelease: Codable, Equatable, Sendable {
    public let contentVersion: UInt32
    public let releaseDate: String?
}

public struct ReleaseSnapshot: Codable, Sendable {
    public let releases: [String: GameRelease]
    public let checkedAt: Date
    public var isStale: Bool { Date().timeIntervalSince(checkedAt) > 86400 }
}

public enum VersionComparison: Equatable {
    case updateAvailable, latestKnown, newerThanCatalogue, unknown
    public static func compare(_ installed: InstalledGameVersion?, release: GameRelease?) -> VersionComparison {
        guard let installed, let release else { return .unknown }
        if installed.contentVersion < release.contentVersion { return .updateAvailable }
        if installed.contentVersion > release.contentVersion { return .newerThanCatalogue }
        return .latestKnown
    }
}

public actor GameReleaseStore {
    public static let sourceURL = URL(string: "https://github.com/blawar/titledb/blob/master/versions.json")!
    private let cache: URL
    private let session: URLSession
    private var snapshot: ReleaseSnapshot?
    private var nextNetworkCheck = Date.distantPast

    public init(cache: URL? = nil, session: URLSession? = nil) {
        self.cache = cache ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/Versions/catalogue.json")
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config)
        }
    }

    public func releases(force: Bool = false) async -> ReleaseSnapshot? {
        if snapshot == nil, let data = try? Data(contentsOf: cache) {
            snapshot = try? JSONDecoder().decode(ReleaseSnapshot.self, from: data)
        }
        if let snapshot, !snapshot.isStale, !force { return snapshot }
        guard Date() >= nextNetworkCheck else { return snapshot }
        nextNetworkCheck = Date().addingTimeInterval(60)
        do {
            var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/versions.json")!)
            request.setValue("Swoosh/0.3 (game release metadata client)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == "raw.githubusercontent.com", data.count <= 10_000_000 else { return snapshot }
            let releases = try Self.parse(data)
            guard !releases.isEmpty else { return snapshot }
            let updated = ReleaseSnapshot(releases: releases, checkedAt: Date())
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: cache, options: .atomic)
            snapshot = updated
        } catch { /* Offline or invalid feed: keep the last known snapshot. */ }
        return snapshot
    }

    public static func parse(_ data: Data) throws -> [String: GameRelease] {
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var releases: [String: GameRelease] = [:]
        for (title, value) in document where InstalledGameVersion.validTitleID(title) {
            guard let history = value as? [String: Any],
                  let latest = history.keys.compactMap(UInt32.init).max() else { continue }
            let key = title.uppercased()
            if let existing = releases[key], existing.contentVersion >= latest { continue }
            releases[key] = GameRelease(contentVersion: latest, releaseDate: history[String(latest)] as? String)
        }
        return releases
    }
}
