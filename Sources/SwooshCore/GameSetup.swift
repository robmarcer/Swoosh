import Foundation

public enum GameSetupError: LocalizedError {
    case invalidApp, duplicate, identity, unsupported, changed, signed, active, unsafePath
    public var errorDescription: String? {
        switch self {
        case .invalidApp: return "Choose a runnable converted macOS game app. Fix its setup diagnostics before importing it."
        case .duplicate: return "This app is already in the library. Open its Setup screen to configure saves."
        case .identity: return "Enter the verified 16-character hexadecimal base title ID. It must match any installed title metadata."
        case .unsupported: return "This launcher cannot be verified for an external save variable. Choose its fixed save folder and copy mode instead."
        case .changed: return "The launcher changed during setup. Recheck the game before trying again."
        case .signed: return "This app is signed. Swoosh will preserve its signature; use fixed-folder copy mode instead of changing its launcher."
        case .active: return "Exit the game before importing or changing its save setup."
        case .unsafePath: return "Choose a dedicated save folder outside Swoosh’s storage. Game installations must stay outside save storage."
        }
    }
}

public struct ImportedGame: Codable, Sendable {
    public let path: String
    public let bookmark: Data
    public var titleID: String?
    public var imported: Bool
    public func resolve() -> URL {
        let original = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: original.path) { return original.resolvingSymlinksInPath() }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? original
    }
}

public struct ProtectedGameSettings: Codable, Sendable {
    public let titleID: String
    public let saves: SaveConfiguration
    public let verification: String
}

/// Local-only records live outside app bundles and game installations.
public final class GameSetupStore {
    public let root: URL
    private let fm = FileManager.default
    public init(root: URL? = nil) {
        self.root = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/GameSetup")
    }
    public func registrations() throws -> [ImportedGame] {
        let url = root.appendingPathComponent("library.json")
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ImportedGame].self, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    public func register(app: URL, titleID: String?, imported: Bool, existing: [Game] = [], activeApps: Set<String> = []) throws {
        let app = app.resolvingSymlinksInPath().standardizedFileURL
        guard !activeApps.contains(app.path) else { throw GameSetupError.active }
        guard let game = Library.inspect(app: app, libraryRoot: Self.metadataRoot(for: app)), game.canLaunch,
              SetupCheck.bundleInfo(app)?["CFBundleIdentifier"] as? String != "dev.swoosh.launcher" else { throw GameSetupError.invalidApp }
        if imported, existing.contains(where: { $0.url.resolvingSymlinksInPath() == app }) { throw GameSetupError.duplicate }
        let normalized = titleID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let normalized {
            guard InstalledGameVersion.validTitleID(normalized), game.installedVersion == nil || game.installedVersion?.titleID == normalized else { throw GameSetupError.identity }
        }
        var records = try registrations()
        let previous = records.first { $0.resolve().resolvingSymlinksInPath() == app }
        records.removeAll { $0.resolve().resolvingSymlinksInPath() == app }
        let bookmark = try app.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        records.append(ImportedGame(path: app.path, bookmark: bookmark, titleID: normalized ?? game.installedVersion?.titleID,
                                    imported: imported || previous?.imported == true))
        try write(records, to: root.appendingPathComponent("library.json"))
    }
    /// Shared Applications-style folders must not supply one sibling profile to unrelated apps.
    public static func metadataRoot(for app: URL) -> URL {
        let parent = app.deletingLastPathComponent()
        let apps = ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension.lowercased() == "app" }
        let sharedNames = ["applications", "downloads", "desktop", "documents", "switch"]
        return apps.count == 1 && !sharedNames.contains(parent.lastPathComponent.lowercased()) && parent != FileManager.default.homeDirectoryForCurrentUser ? parent.deletingLastPathComponent() : parent
    }
    public func games(discovered: [Game], libraryRoot: URL) throws -> [Game] {
        var result = discovered
        for record in try registrations() {
            let app = record.resolve().resolvingSymlinksInPath().standardizedFileURL
            if let index = result.firstIndex(where: { $0.url == app }) {
                if let id = record.titleID, InstalledGameVersion.validTitleID(id), result[index].installedVersion == nil || result[index].installedVersion?.titleID == id {
                    result[index].configuredTitleID = id
                }
            } else if record.imported, var game = Library.inspect(app: app, libraryRoot: Self.metadataRoot(for: app)) {
                if let id = record.titleID, InstalledGameVersion.validTitleID(id), game.installedVersion == nil || game.installedVersion?.titleID == id { game.configuredTitleID = id }
                result.append(game)
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func settings(titleID: String) throws -> ProtectedGameSettings? {
        guard InstalledGameVersion.validTitleID(titleID) else { throw GameSetupError.identity }
        let url = root.appendingPathComponent("Titles/" + titleID.uppercased() + ".json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(ProtectedGameSettings.self, from: Data(contentsOf: url))
        guard value.titleID == titleID.uppercased(), ["supported-wrapper", "explicit-copy"].contains(value.verification) else { throw GameSetupError.identity }
        return value
    }
    public func save(titleID: String, configuration: SaveConfiguration, verification: String) throws {
        guard InstalledGameVersion.validTitleID(titleID), ["supported-wrapper", "explicit-copy"].contains(verification) else { throw GameSetupError.identity }
        try configuration.validate()
        try write(ProtectedGameSettings(titleID: titleID.uppercased(), saves: configuration, verification: verification),
                  to: root.appendingPathComponent("Titles/" + titleID.uppercased() + ".json"))
    }
    public func configuration(game: Game, libraryRoot: URL) throws -> SaveConfiguration? {
        if let id = game.titleID, let saved = try settings(titleID: id) {
            if saved.saves.mode == .environment {
                guard let assessment = NXnativeSetup.assess(app: game.url, titleID: id), assessment.preservesSaveVariable else { throw GameSetupError.unsupported }
            }
            return saved.saves
        }
        let legacy = try SaveConfiguration.read(game: game, libraryRoot: libraryRoot)
        if legacy?.mode == .environment {
            guard let assessment = NXnativeSetup.assess(app: game.url, titleID: game.titleID), assessment.preservesSaveVariable else { throw GameSetupError.unsupported }
        }
        return legacy
    }
}

public struct WrapperAssessment: Sendable {
    public let executable: URL
    public let original: Data
    public let saveFolder: URL
    public let preservesSaveVariable: Bool
    public let canRepair: Bool
}

public enum NXnativeSetup {
    public static func assess(app: URL, titleID: String?) -> WrapperAssessment? {
        guard let info = SetupCheck.bundleInfo(app), let executableName = info["CFBundleExecutable"] as? String,
              !executableName.contains("/"), executableName != ".", executableName != ".." else { return nil }
        let executable = app.appendingPathComponent("Contents/MacOS/" + executableName)
        guard executable.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/") else { return nil }
        guard let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: executable), data.count < 65536, let script = String(data: data, encoding: .utf8) else { return nil }
        let lines = script.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count == 15, lines[0] == "#!/bin/sh", lines[1] == "set -eu",
              lines[2] == "APP_CONTENTS=\"$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\"",
              lines[3] == "export DM_ROOT=\"$(CDPATH= cd -- \"$APP_CONTENTS/../../GameData\" && pwd)\"",
              lines[4].hasPrefix("STATE_DIR=\"$HOME/Library/Application Support/nxnative/"), lines[4].hasSuffix("\""),
              lines[5].range(of: #"^export DM_ROMFS="\$DM_ROOT/extract/v[0-9]+/RomFS"$"#, options: .regularExpression) != nil,
              ["export DM_SAVE=\"$STATE_DIR/save\"", "export DM_SAVE=\"${DM_SAVE:-$STATE_DIR/save}\""].contains(lines[6]),
              lines[7] == "export DM_TEMP=\"$STATE_DIR/temp\"",
              lines[8] == "export DM_MSL_DIR=\"$DM_ROOT/shader/cache\"",
              lines[9] == "export DM_FONT_DIR=\"$DM_ROOT/font\"",
              lines[10].range(of: #"^export DM_NVN_SHMAP="\$DM_ROOT/profile/[0-9A-Fa-f]{16}/shader_map\.tsv"$"#, options: .regularExpression) != nil,
              lines[11] == "export DM_LANG=en-US DM_WINDOW=1 DM_AUDIO=1",
              lines[12] == "mkdir -p \"$DM_SAVE\" \"$DM_TEMP\"",
              lines[13] == "cd \"$STATE_DIR\"",
              lines[14].range(of: #"^exec "\$APP_CONTENTS/MacOS/dmhost" "\$DM_ROOT/patched_v[0-9]+" > "\$STATE_DIR/launcher\.log" 2>&1$"#, options: .regularExpression) != nil else { return nil }
        let prefix = "STATE_DIR=\"$HOME/Library/Application Support/nxnative/"
        let name = String(lines[4].dropFirst(prefix.count).dropLast())
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-!()'"))
        guard !name.isEmpty, name.count <= 150, name != ".", name != "..", name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        if let titleID, !lines[10].uppercased().contains("/" + titleID.uppercased() + "/") { return nil }
        let romVersion = lines[5].components(separatedBy: "/extract/")[1].components(separatedBy: "/")[0]
        guard lines[14].contains("/patched_" + romVersion + "\"") else { return nil }
        let dataRoot = app.deletingLastPathComponent().appendingPathComponent("GameData")
        let wrapperID = lines[10].components(separatedBy: "/profile/")[1].components(separatedBy: "/")[0].uppercased()
        guard let text = try? String(contentsOf: dataRoot.appendingPathComponent("profile/" + wrapperID + "/game.tsv")),
              let profile = InstalledGameVersion.profile(text), profile.titleID == wrapperID,
              "v" + String(profile.contentVersion) == romVersion,
              FileManager.default.isReadableFile(atPath: dataRoot.appendingPathComponent("extract/" + romVersion + "/RomFS").path),
              FileManager.default.isReadableFile(atPath: dataRoot.appendingPathComponent("patched_" + romVersion).path),
              FileManager.default.isReadableFile(atPath: dataRoot.appendingPathComponent("profile/" + wrapperID + "/shader_map.tsv").path) else { return nil }
        let signed = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_CodeSignature").path) || FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/CodeResources").path)
        let preserves = lines[6].contains("${DM_SAVE:-")
        return WrapperAssessment(executable: executable, original: data,
                                 saveFolder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative/" + name + "/save"),
                                 preservesSaveVariable: preserves, canRepair: !signed)
    }

    public static func repair(_ assessment: WrapperAssessment, backupRoot: URL) throws -> URL? {
        if assessment.preservesSaveVariable { return nil }
        guard assessment.canRepair else { throw GameSetupError.signed }
        let fm = FileManager.default
        guard try Data(contentsOf: assessment.executable) == assessment.original else { throw GameSetupError.changed }
        let original = "export DM_SAVE=\"$STATE_DIR/save\""
        let replacement = "export DM_SAVE=\"${DM_SAVE:-$STATE_DIR/save}\""
        guard let text = String(data: assessment.original, encoding: .utf8), text.components(separatedBy: original).count == 2 else { throw GameSetupError.unsupported }
        let backup = backupRoot.appendingPathComponent(UUID().uuidString).appendingPathComponent("launcher")
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: assessment.executable, to: backup)
        let permissions = try fm.attributesOfItem(atPath: assessment.executable.path)[.posixPermissions] ?? 0o755
        try Data(text.replacingOccurrences(of: original, with: replacement).utf8).write(to: assessment.executable, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: assessment.executable.path)
        return backup
    }
    public static func undoRepair(_ assessment: WrapperAssessment) throws {
        guard let text = String(data: assessment.original, encoding: .utf8) else { return }
        let repaired = Data(text.replacingOccurrences(of: "export DM_SAVE=\"$STATE_DIR/save\"", with: "export DM_SAVE=\"${DM_SAVE:-$STATE_DIR/save}\"").utf8)
        guard try Data(contentsOf: assessment.executable) == repaired else { throw GameSetupError.changed }
        let permissions = try FileManager.default.attributesOfItem(atPath: assessment.executable.path)[.posixPermissions] ?? 0o755
        try assessment.original.write(to: assessment.executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: assessment.executable.path)
    }
}
