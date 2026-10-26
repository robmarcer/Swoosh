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
    case invalidConfiguration, missingIdentity, unsafeTree, activeSession, conflict, invalidBackup, storageUnavailable, locationConflict
    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "The selected save folder is unavailable or not downloaded. Reconnect its drive, or use Download Now / Keep Downloaded in Finder, then try again. Existing saves remain protected."
        case .locationConflict: return "That folder contains different saves for the same title. Choose another folder; neither copy has been overwritten."
        case .invalidConfiguration: return "Save configuration is invalid. Set an explicit save folder and supported runtime environment variable in SwooshGame.json."
        case .missingIdentity: return "A verified title ID is required before Swoosh can manage saves. Add verified title metadata to SwooshGame.json."
        case .unsafeTree: return "The save folder contains a symlink, special file, or unsafe location. No saves were overwritten."
        case .activeSession: return "A previous game session is still running. Exit it before preparing or restoring saves."
        case .conflict: return "External saves changed during an interrupted session. Both copies are preserved. Inspect the Recovery folder in the save location or in Swoosh/SaveSessions under Application Support before resolving the conflict."
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
    public private(set) var root: URL
    private var sessionRoot: URL?
    private var requiresExistingRoot: Bool
    public static var defaultRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/Saves") }
    public static var localSessions: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/SaveSessions") }
    private let fm = FileManager.default
    public init(root: URL? = nil, sessionRoot: URL? = nil, requiresExistingRoot: Bool = false) {
        self.root = root ?? Self.defaultRoot
        self.sessionRoot = sessionRoot
        self.requiresExistingRoot = requiresExistingRoot
    }

    private func coordinated<T>(_ operation: () throws -> T) throws -> T {
        if requiresExistingRoot {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw SaveError.storageUnavailable }
            try requireDownloaded(root)
        } else { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError) { _ in
            result = Result { try operation() }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SaveError.storageUnavailable }
        return try result.get()
    }

    private func requireDownloaded(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey])
        if values.ubiquitousItemHasUnresolvedConflicts == true { throw SaveError.locationConflict }
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw SaveError.storageUnavailable
        }
    }
    private func sessionDirectory(_ titleID: String) throws -> URL {
        guard let sessionRoot else { return try directory(titleID) }
        let url = sessionRoot.appendingPathComponent(titleID.uppercased())
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// The selected directory is dedicated to Swoosh. Existing, identical title folders can be re-used.
    /// Original storage is retained after a successful migration.
    public func changeLocation(to destination: URL, sessionRoot newSessions: URL?, activeApps: Set<String> = [], forbiddenRoots: [URL] = []) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let origin = root.resolvingSymlinksInPath().standardizedFileURL
        if target == origin { return }
        guard !target.path.hasPrefix(origin.path + "/"), !origin.path.hasPrefix(target.path + "/"),
              target != fm.homeDirectoryForCurrentUser, target.path != "/",
              !forbiddenRoots.contains(where: { target.path == $0.resolvingSymlinksInPath().path || target.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }),
              newSessions.map({ !target.path.hasPrefix($0.path + "/") && !$0.path.hasPrefix(target.path + "/") && target != $0 }) ?? true else { throw SaveError.unsafeTree }
        try coordinated {
            let sourceEntries = try fm.contentsOfDirectory(at: origin, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for entry in sourceEntries {
                guard InstalledGameVersion.validTitleID(entry.lastPathComponent) else { throw SaveError.unsafeTree }
                try _recover(titleID: entry.lastPathComponent, activeApps: activeApps)
            }
            if let sessionRoot, let sessions = try? fm.contentsOfDirectory(at: sessionRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for session in sessions where fm.fileExists(atPath: session.appendingPathComponent("session.json").path) {
                    try _recover(titleID: session.lastPathComponent, activeApps: activeApps)
                }
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forMerging, error: &coordinationError) { _ in
                result = Result {
                    let before = try tree(origin).0
                    let existed = fm.fileExists(atPath: target.path)
                    if existed { try requireDownloaded(target) }
                    let destinationBefore = existed ? try tree(target).0 : nil
                    let staged = target.deletingLastPathComponent().appendingPathComponent(".swoosh-location-" + UUID().uuidString)
                    defer { try? fm.removeItem(at: staged) }
                    if existed { try checkedCopy(target, to: staged) }
                    else { try fm.createDirectory(at: staged, withIntermediateDirectories: true) }
                    let entries = try fm.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    guard entries.allSatisfy({ InstalledGameVersion.validTitleID($0.lastPathComponent) && !fm.fileExists(atPath: $0.appendingPathComponent("session.json").path) }), Set(entries.map { $0.lastPathComponent.uppercased() }).count == entries.count else { throw SaveError.locationConflict }
                    for entry in sourceEntries {
                        let next = staged.appendingPathComponent(entry.lastPathComponent)
                        if fm.fileExists(atPath: next.path) {
                            guard try tree(entry).0 == tree(next).0 else { throw SaveError.locationConflict }
                        } else { try checkedCopy(entry, to: next) }
                    }
                    guard try tree(origin).0 == before else { throw SaveError.conflict }
                    if existed { guard try tree(target).0 == destinationBefore else { throw SaveError.locationConflict } }
                    else { guard !fm.fileExists(atPath: target.path) else { throw SaveError.locationConflict } }
                    try install(staged, at: target)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw SaveError.storageUnavailable }
            try result.get()
        }
        root = target; sessionRoot = newSessions; requiresExistingRoot = true
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
        try requireDownloaded(directory)
        var hash = SHA256(); var bytes: Int64 = 0
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw SaveError.unsafeTree }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL { urls.append(url) }
        guard !enumerationFailed else { throw SaveError.unsafeTree }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            try requireDownloaded(url)
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
    /// Setup must never replace a different existing protected save set implicitly.
    public func validateSetupSource(titleID: String, app: URL, config: SaveConfiguration, activeApps: Set<String> = []) throws {
        try coordinated {
            guard !activeApps.contains(app.resolvingSymlinksInPath().path) else { throw SaveError.activeSession }
            try config.validate()
            let source = try config.source(beside: app)
            let rootPath = root.resolvingSymlinksInPath().path
            guard source.path != rootPath, !source.path.hasPrefix(rootPath + "/"), !rootPath.hasPrefix(source.path + "/") else { throw SaveError.unsafeTree }
            let dir = try directory(titleID)
            let live = dir.appendingPathComponent("live")
            guard fm.fileExists(atPath: live.path) else { return }
            let candidate = dir.appendingPathComponent(".setup-check-" + UUID().uuidString)
            defer { try? fm.removeItem(at: candidate) }
            try capture(source: source, config: config, to: candidate)
            guard try tree(live).0 == tree(candidate).0 else { throw SaveError.locationConflict }
        }
    }

    public func prepare(titleID: String, app: URL, config: SaveConfiguration, activeApps: Set<String> = []) throws -> [String: String] {
        try coordinated { try _prepare(titleID: titleID, app: app, config: config, activeApps: activeApps) }
    }
    public func recover(titleID: String, activeApps: Set<String> = []) throws {
        try coordinated { try _recover(titleID: titleID, activeApps: activeApps) }
    }
    @discardableResult public func backup(titleID: String, reason: String) throws -> SaveBackup {
        try coordinated { try _backup(titleID: titleID, reason: reason) }
    }
    public func summary(titleID: String) throws -> SaveSummary {
        try coordinated { try _summary(titleID: titleID) }
    }
    public func setRetention(titleID: String, count: Int) throws {
        try coordinated { try _setRetention(titleID: titleID, count: count) }
    }
    public func restore(titleID: String, backupID: String, activeApps: Set<String> = []) throws {
        try coordinated { try _restore(titleID: titleID, backupID: backupID, activeApps: activeApps) }
    }

    private func _prepare(titleID: String, app: URL, config: SaveConfiguration, activeApps: Set<String> = []) throws -> [String: String] {
        try config.validate()
        guard !activeApps.contains(app.resolvingSymlinksInPath().path) else { throw SaveError.activeSession }
        let dir = try directory(titleID)
        let source = try config.source(beside: app)
        let rootPath = root.resolvingSymlinksInPath().path
        guard !source.path.hasPrefix(rootPath + "/"), !rootPath.hasPrefix(source.path + "/"), source.path != rootPath else { throw SaveError.unsafeTree }
        try _recover(titleID: titleID, activeApps: activeApps)
        let live = dir.appendingPathComponent("live")
        if !fm.fileExists(atPath: live.path) {
            guard fm.fileExists(atPath: source.path) else { throw SaveError.invalidConfiguration }
            let staged = dir.appendingPathComponent(".migration-" + UUID().uuidString)
            try capture(source: source, config: config, to: staged)
            _ = try tree(staged)
            try install(staged, at: live)
            // Original runtime saves remain untouched after migration.
        }
        _ = try _backup(titleID: titleID, reason: "Before launch")
        let baseline = try tree(live).0
        let session = try sessionDirectory(titleID)
        let working = session.appendingPathComponent("live")
        if sessionRoot != nil {
            let staged = session.appendingPathComponent(".prepare-" + UUID().uuidString)
            try checkedCopy(live, to: staged)
            try install(staged, at: working)
        }
        let journal = session.appendingPathComponent("session.json")
        var entry = SaveJournal(appPath: app.resolvingSymlinksInPath().path, config: config, sourcePath: source.path, baseline: baseline, ready: false)
        try write(entry, journal)
        if config.mode == .copy {
            let old = dir.appendingPathComponent("Recovery", isDirectory: true).appendingPathComponent(UUID().uuidString)
            try capture(source: source, config: config, to: old)
            if try tree(old).0 == tree(live).0 { try fm.removeItem(at: old) }
            try deploy(working, source: source, config: config)
        }
        entry.ready = true; try write(entry, journal)
        if config.mode == .environment { return [config.environmentVariable!: working.appendingPathComponent("save").path] }
        return [:]
    }
    private func _recover(titleID: String, activeApps: Set<String> = []) throws {
        let dir = try directory(titleID), session = try sessionDirectory(titleID)
        let journal = session.appendingPathComponent("session.json")
        guard fm.fileExists(atPath: journal.path) else { return }
        let entry = try read(SaveJournal.self, journal)
        guard !activeApps.contains(entry.appPath) else { throw SaveError.activeSession }
        let live = dir.appendingPathComponent("live")
        if entry.ready, entry.config.mode == .copy || sessionRoot != nil {
            let recovered = session.appendingPathComponent("Recovery/" + UUID().uuidString)
            if entry.config.mode == .copy {
                guard fm.fileExists(atPath: entry.sourcePath) else { throw SaveError.conflict }
                try capture(source: URL(fileURLWithPath: entry.sourcePath), config: entry.config, to: recovered)
            } else {
                try capture(source: session.appendingPathComponent("live/save"), config: entry.config, to: recovered)
            }
            let currentDigest = try tree(live).0
            if currentDigest == (try tree(recovered).0) {
                try? fm.removeItem(at: recovered)
                try fm.removeItem(at: journal)
                return
            }
            guard currentDigest == entry.baseline else { throw SaveError.conflict }
            let staged = dir.appendingPathComponent(".sync-" + UUID().uuidString)
            try checkedCopy(recovered, to: staged)
            try install(staged, at: live)
            try? fm.removeItem(at: recovered)
        }
        try fm.removeItem(at: journal)
    }
    @discardableResult private func _backup(titleID: String, reason: String) throws -> SaveBackup {
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
    private func _summary(titleID: String) throws -> SaveSummary {
        let dir = try directory(titleID), backups = dir.appendingPathComponent("Backups")
        let items = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).compactMap { try? read(SaveBackup.self, $0.appendingPathComponent("backup.json")) }.sorted { $0.date > $1.date }
        let retention = (try? read(Int.self, dir.appendingPathComponent("retention.json"))) ?? 10
        return SaveSummary(location: dir, backups: items, bytes: try tree(dir).1, retention: retention)
    }
    private func _setRetention(titleID: String, count: Int) throws {
        guard [5, 10, 20].contains(count) else { throw SaveError.invalidConfiguration }
        try write(count, try directory(titleID).appendingPathComponent("retention.json"))
        try prune(titleID: titleID)
    }
    private func prune(titleID: String) throws {
        let summary = try _summary(titleID: titleID)
        for item in summary.backups.dropFirst(summary.retention) {
            try fm.removeItem(at: summary.location.appendingPathComponent("Backups/" + item.id))
        }
    }
    private func _restore(titleID: String, backupID: String, activeApps: Set<String> = []) throws {
        guard UUID(uuidString: backupID) != nil else { throw SaveError.invalidBackup }
        try _recover(titleID: titleID, activeApps: activeApps)
        let dir = try directory(titleID), folder = dir.appendingPathComponent("Backups/" + backupID)
        let metadata = try read(SaveBackup.self, folder.appendingPathComponent("backup.json"))
        guard metadata.id == backupID, try tree(folder.appendingPathComponent("data")).0 == metadata.digest else { throw SaveError.invalidBackup }
        let staged = dir.appendingPathComponent(".restore-" + UUID().uuidString)
        try checkedCopy(folder.appendingPathComponent("data"), to: staged)
        _ = try _backup(titleID: titleID, reason: "Before restore")
        try install(staged, at: dir.appendingPathComponent("live"))
    }
}
