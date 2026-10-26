import Foundation
import CryptoKit
import Darwin

public struct SaveConfiguration: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case environment, copy }
    public let mode: Mode
    public let path: String
    public let environmentVariable: String?
    public let companionSuffixes: [String]?
    public init(mode: Mode, path: String, environmentVariable: String? = nil, companionSuffixes: [String]? = nil) {
        self.mode = mode; self.path = path; self.environmentVariable = environmentVariable; self.companionSuffixes = companionSuffixes
    }
    public static func read(game: Game, libraryRoot: URL) throws -> SaveConfiguration? {
        let parent = game.url.deletingLastPathComponent()
        guard parent != libraryRoot else { return nil }
        let manifest = parent.appendingPathComponent("SwooshGame.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        struct Manifest: Decodable { let saves: SaveConfiguration? }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).saves
    }
    public func source(beside app: URL) throws -> URL {
        guard !path.isEmpty else { throw SaveError.invalidConfiguration }
        let expanded = (path as NSString).expandingTildeInPath
        let result: URL
        if expanded.hasPrefix("/") { result = URL(fileURLWithPath: expanded) }
        else if let relative = SetupCheck.relativePath(expanded, beneath: app.deletingLastPathComponent()) { result = relative }
        else { throw SaveError.invalidConfiguration }
        let resolved = result.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path != "/", resolved != FileManager.default.homeDirectoryForCurrentUser else { throw SaveError.invalidConfiguration }
        return resolved
    }
    var suffixes: [String] {
        [""] + (companionSuffixes ?? (environmentVariable == "DM_SAVE" ? ["_device"] : []))
    }
    func validate() throws {
        if mode == .environment {
            guard let name = environmentVariable, name.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil,
                  !["HOME", "PATH", "TMPDIR", "SHELL"].contains(name), !name.hasPrefix("DYLD_") else { throw SaveError.invalidConfiguration }
        }
        guard suffixes.count <= 10, Set(suffixes).count == suffixes.count,
              suffixes.dropFirst().allSatisfy({ $0.range(of: "^_[A-Za-z0-9_]{1,32}$", options: .regularExpression) != nil }) else { throw SaveError.invalidConfiguration }
    }
}

public enum SaveError: LocalizedError {
    case invalidConfiguration, missingIdentity, unsafeTree, activeSession, conflict, invalidBackup
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Save configuration is invalid. Set an explicit save folder and supported runtime environment variable in SwooshGame.json."
        case .missingIdentity: return "A verified title ID is required before Swoosh can manage saves. Add verified title metadata to SwooshGame.json."
        case .unsafeTree: return "The save folder contains a symlink, special file, or unsafe location. No saves were overwritten."
        case .activeSession: return "A previous game session is still running. Exit it before preparing or restoring saves."
        case .conflict: return "External saves changed during an interrupted session. Both copies are preserved; inspect the recovery folder before resolving the conflict."
        case .invalidBackup: return "The backup failed verification. Existing saves have not been replaced."
        }
    }
}

public struct SaveBackup: Identifiable, Codable, Sendable {
    public let id: String
    public let date: Date
    public let reason: String
    public let digest: String
    public let bytes: Int64
}
public struct SaveSummary: Sendable {
    public let location: URL
    public let backups: [SaveBackup]
    public let bytes: Int64
    public let retention: Int
}
private struct SaveJournal: Codable {
    let appPath: String
    let config: SaveConfiguration
    let sourcePath: String
    let baseline: String
    var ready: Bool
}

/// All mutations are serialized. Snapshots are verified before atomic directory swaps.
public actor SaveStore {
    public let root: URL
    private let fm = FileManager.default
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/Saves")
    }
    private func directory(_ titleID: String) throws -> URL {
        guard InstalledGameVersion.validTitleID(titleID) else { throw SaveError.missingIdentity }
        let url = root.appendingPathComponent(titleID.uppercased())
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    private func write<T: Encodable>(_ value: T, _ url: URL) throws { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
    private func tree(_ directory: URL) throws -> (String, Int64) {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        var hash = SHA256(); var bytes: Int64 = 0
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw SaveError.unsafeTree }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL { urls.append(url) }
        guard !enumerationFailed else { throw SaveError.unsafeTree }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw SaveError.unsafeTree }
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(directory.path.count))
            let pathData = Data(relative.utf8)
            var length = UInt64(pathData.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: pathData)
            hash.update(data: Data([values.isDirectory == true ? 0 : 1]))
            if values.isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value.bigEndian ?? 0
                withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data); bytes += Int64(data.count) }
            }
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    private func checkedCopy(_ source: URL, to target: URL) throws {
        guard (try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).isSymbolicLink != true,
              (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw SaveError.unsafeTree }
        let before = try tree(source).0
        try fm.copyItem(at: source, to: target)
        let after = try tree(target).0
        guard after == before, (try tree(source).0) == before else {
            throw SaveError.invalidBackup
        }
    }
    private func install(_ staged: URL, at target: URL) throws {
        if fm.fileExists(atPath: target.path) {
            guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try? fm.removeItem(at: staged) // Swapped-out data is already protected by a snapshot.
        } else { try fm.moveItem(at: staged, to: target) }
    }
    private func capture(source: URL, config: SaveConfiguration, to target: URL) throws {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for suffix in config.suffixes {
            let item = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: item.path) { try checkedCopy(item, to: target.appendingPathComponent("save" + suffix)) }
            else if suffix.isEmpty { try fm.createDirectory(at: target.appendingPathComponent("save"), withIntermediateDirectories: true) }
        }
    }
    private func deploy(_ live: URL, source: URL, config: SaveConfiguration) throws {
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in config.suffixes {
            let origin = live.appendingPathComponent("save" + suffix)
            let target = URL(fileURLWithPath: source.path + suffix)
            let staged = target.deletingLastPathComponent().appendingPathComponent(".swoosh-" + UUID().uuidString)
            if fm.fileExists(atPath: origin.path) { try checkedCopy(origin, to: staged) }
            else { try fm.createDirectory(at: staged, withIntermediateDirectories: true) }
            try install(staged, at: target)
        }
    }
    public func prepare(titleID: String, app: URL, config: SaveConfiguration, activeApps: Set<String> = []) throws -> [String: String] {
        try config.validate()
        guard !activeApps.contains(app.resolvingSymlinksInPath().path) else { throw SaveError.activeSession }
        let dir = try directory(titleID)
        let source = try config.source(beside: app)
        let rootPath = root.resolvingSymlinksInPath().path
        guard !source.path.hasPrefix(rootPath + "/"), !rootPath.hasPrefix(source.path + "/"), source.path != rootPath else { throw SaveError.unsafeTree }
        try recover(titleID: titleID, activeApps: activeApps)
        let live = dir.appendingPathComponent("live")
        if !fm.fileExists(atPath: live.path) {
            guard fm.fileExists(atPath: source.path) else { throw SaveError.invalidConfiguration }
            let staged = dir.appendingPathComponent(".migration-" + UUID().uuidString)
            try capture(source: source, config: config, to: staged)
            _ = try tree(staged)
            try install(staged, at: live)
            // Original runtime saves remain untouched after migration.
        }
        _ = try backup(titleID: titleID, reason: "Before launch")
        let baseline = try tree(live).0
        let journal = dir.appendingPathComponent("session.json")
        var entry = SaveJournal(appPath: app.resolvingSymlinksInPath().path, config: config, sourcePath: source.path, baseline: baseline, ready: false)
        try write(entry, journal)
        if config.mode == .copy {
            let old = dir.appendingPathComponent("Recovery", isDirectory: true).appendingPathComponent(UUID().uuidString)
            try capture(source: source, config: config, to: old)
            if try tree(old).0 == tree(live).0 { try fm.removeItem(at: old) }
            try deploy(live, source: source, config: config)
        }
        entry.ready = true; try write(entry, journal)
        if config.mode == .environment { return [config.environmentVariable!: live.appendingPathComponent("save").path] }
        return [:]
    }
    public func recover(titleID: String, activeApps: Set<String> = []) throws {
        let dir = try directory(titleID), journal = dir.appendingPathComponent("session.json")
        guard fm.fileExists(atPath: journal.path) else { return }
        let entry = try read(SaveJournal.self, journal)
        guard !activeApps.contains(entry.appPath) else { throw SaveError.activeSession }
        let live = dir.appendingPathComponent("live")
        if entry.config.mode == .copy, entry.ready {
            guard fm.fileExists(atPath: entry.sourcePath) else { throw SaveError.conflict }
            let recovered = dir.appendingPathComponent("Recovery/" + UUID().uuidString)
            try capture(source: URL(fileURLWithPath: entry.sourcePath), config: entry.config, to: recovered)
            guard try tree(live).0 == entry.baseline else { throw SaveError.conflict }
            let staged = dir.appendingPathComponent(".sync-" + UUID().uuidString)
            try checkedCopy(recovered, to: staged)
            try install(staged, at: live)
            try? fm.removeItem(at: recovered)
        }
        try fm.removeItem(at: journal)
    }
    @discardableResult public func backup(titleID: String, reason: String) throws -> SaveBackup {
        let dir = try directory(titleID), live = dir.appendingPathComponent("live")
        let id = UUID().uuidString
        let backups = dir.appendingPathComponent("Backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let staged = backups.appendingPathComponent(".pending-" + id), final = backups.appendingPathComponent(id)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try checkedCopy(live, to: staged.appendingPathComponent("data"))
        let (digest, bytes) = try tree(staged.appendingPathComponent("data"))
        let item = SaveBackup(id: id, date: Date(), reason: reason, digest: digest, bytes: bytes)
        try write(item, staged.appendingPathComponent("backup.json"))
        try fm.moveItem(at: staged, to: final)
        try prune(titleID: titleID)
        return item
    }
    public func summary(titleID: String) throws -> SaveSummary {
        let dir = try directory(titleID), backups = dir.appendingPathComponent("Backups")
        let items = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).compactMap { try? read(SaveBackup.self, $0.appendingPathComponent("backup.json")) }.sorted { $0.date > $1.date }
        let retention = (try? read(Int.self, dir.appendingPathComponent("retention.json"))) ?? 10
        return SaveSummary(location: dir, backups: items, bytes: try tree(dir).1, retention: retention)
    }
    public func setRetention(titleID: String, count: Int) throws {
        guard [5, 10, 20].contains(count) else { throw SaveError.invalidConfiguration }
        try write(count, try directory(titleID).appendingPathComponent("retention.json"))
        try prune(titleID: titleID)
    }
    private func prune(titleID: String) throws {
        let summary = try summary(titleID: titleID)
        for item in summary.backups.dropFirst(summary.retention) {
            try fm.removeItem(at: summary.location.appendingPathComponent("Backups/" + item.id))
        }
    }
    public func restore(titleID: String, backupID: String, activeApps: Set<String> = []) throws {
        guard UUID(uuidString: backupID) != nil else { throw SaveError.invalidBackup }
        try recover(titleID: titleID, activeApps: activeApps)
        let dir = try directory(titleID), folder = dir.appendingPathComponent("Backups/" + backupID)
        let metadata = try read(SaveBackup.self, folder.appendingPathComponent("backup.json"))
        guard metadata.id == backupID, try tree(folder.appendingPathComponent("data")).0 == metadata.digest else { throw SaveError.invalidBackup }
        let staged = dir.appendingPathComponent(".restore-" + UUID().uuidString)
        try checkedCopy(folder.appendingPathComponent("data"), to: staged)
        _ = try backup(titleID: titleID, reason: "Before restore")
        try install(staged, at: dir.appendingPathComponent("live"))
    }
}
