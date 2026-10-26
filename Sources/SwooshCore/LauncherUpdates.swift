import Foundation
import CryptoKit
import Darwin
import Security

public struct LauncherVersion: Comparable, Equatable, Sendable {
    let numbers: [Int]
    let prerelease: [String]
    public init?(_ raw: String) {
        let raw = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard raw.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z.-]+)?$", options: .regularExpression) != nil else { return nil }
        let version = raw.components(separatedBy: "+")[0].split(separator: "-", maxSplits: 1).map(String.init)
        let values = version[0].split(separator: ".").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        numbers = values; prerelease = version.count == 2 ? version[1].split(separator: ".").map(String.init) : []
        guard prerelease.allSatisfy({ Int($0) == nil || $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }; if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct LauncherRelease: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let name: String
        public let digest: String?
        public let size: Int64
    }
    public let tag_name: String
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public var archiveName: String { "Swoosh-\(tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name)-macos-arm64.zip" }
    public var archive: Asset? { assets.first { $0.name == archiveName } }
    public static func newest(in data: Data, installed: String, includePrereleases: Bool) throws -> LauncherRelease? {
        guard let installed = LauncherVersion(installed), data.count <= 8_000_000 else { throw UpdateError.invalidRelease }
        return try JSONDecoder().decode([LauncherRelease].self, from: data).filter {
            !$0.draft && (includePrereleases || (!$0.prerelease && LauncherVersion($0.tag_name)?.prerelease.isEmpty == true)) && LauncherVersion($0.tag_name).map { $0 > installed } == true
                && $0.archive != nil && $0.assets.contains { $0.name == "SHA256SUMS.txt" }
        }.max { LauncherVersion($0.tag_name)! < LauncherVersion($1.tag_name)! }
    }
}

public enum UpdateError: LocalizedError {
    case authentication, invalidRelease, checksum, invalidBundle, permissions, failedCommand, parentStillRunning
    public var errorDescription: String? {
        switch self {
        case .authentication: return "Install GitHub CLI and sign in with gh auth login using an account with repository access, or download the release manually."
        case .invalidRelease: return "No valid update metadata is available. Use the release page to update manually."
        case .checksum: return "The downloaded archive failed checksum verification. The installed app has not changed."
        case .invalidBundle: return "The update failed app identity, version, architecture or signature verification. The installed app has not changed."
        case .permissions: return "The app's folder is not writable. Move Swoosh to a writable Applications folder or install the release manually."
        case .failedCommand: return "The update operation could not complete. Retry when online or use the release page."
        case .parentStillRunning: return "Swoosh did not exit in time. The update was not installed."
        }
    }
}

public enum UpdateCommand {
    /// Arguments are passed directly, never through a shell. Output is file-backed to avoid pipe deadlocks.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 90) throws -> Data {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("Swoosh-command-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("stdout")
        fm.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_NO_UPDATE_NOTIFIER"] = "1"; environment["GH_HOST"] = "github.com"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.2); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.failedCommand }
        guard (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0 <= 8_000_000 else { throw UpdateError.invalidRelease }
        return try Data(contentsOf: output)
    }
}

public actor LauncherUpdateStore {
    public let repository: String
    public init(repository: String) { self.repository = repository }
    private func cli() throws -> String {
        guard let cli = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw UpdateError.authentication }
        return cli
    }
    public func check(installed: String, includePrereleases: Bool) throws -> LauncherRelease? {
        do {
            let data = try UpdateCommand.run(try cli(), ["api", "--hostname", "github.com", "repos/" + repository + "/releases?per_page=100"])
            return try LauncherRelease.newest(in: data, installed: installed, includePrereleases: includePrereleases)
        } catch UpdateError.failedCommand { throw UpdateError.authentication }
    }
    public func download(_ release: LauncherRelease, to directory: URL) throws -> URL {
        guard LauncherVersion(release.tag_name) != nil, let asset = release.archive, asset.size > 0, asset.size <= 200_000_000 else { throw UpdateError.invalidRelease }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try UpdateCommand.run(try cli(), ["release", "download", release.tag_name, "--repo", "github.com/" + repository, "--pattern", release.archiveName, "--pattern", "SHA256SUMS.txt", "--dir", directory.path])
        let archive = directory.appendingPathComponent(release.archiveName)
        let digest = try UpdateValidation.sha256(archive)
        guard (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value == asset.size else { throw UpdateError.checksum }
        let checksums = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS.txt"), encoding: .utf8)
        guard UpdateValidation.checksum(checksums, filename: release.archiveName) == digest else { throw UpdateError.checksum }
        if let expected = asset.digest { guard expected == "sha256:" + digest else { throw UpdateError.checksum } }
        return archive
    }
}

public enum UpdateValidation {
    public static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func checksum(_ text: String, filename: String) -> String? {
        let matches = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count == 2, parts[1] == filename || parts[1] == "*" + filename,
                  parts[0].range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { return nil }
            return parts[0].lowercased()
        }
        return matches.count == 1 ? matches[0] : nil
    }
    public static func validArchivePaths(_ text: String) -> Bool {
        let paths = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return !paths.isEmpty && paths.allSatisfy { path in
            (path == "Swoosh.app/" || path.hasPrefix("Swoosh.app/")) && !path.split(separator: "/").contains("..") && !path.contains("\\") && !path.contains("\0")
        }
    }
    public static func validateBundle(_ app: URL, expectedVersion: String, installed: URL) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.swoosh.launcher", info["CFBundleExecutable"] as? String == "Swoosh",
              let version = info["CFBundleShortVersionString"] as? String, let parsed = LauncherVersion(version), let expected = LauncherVersion(expectedVersion), parsed == expected,
              let minimum = info["LSMinimumSystemVersion"] as? String else { throw UpdateError.invalidBundle }
        let components = minimum.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty, components.count == minimum.split(separator: ".", omittingEmptySubsequences: false).count, components.count <= 3 else { throw UpdateError.invalidBundle }
        let minimumOS = OperatingSystemVersion(majorVersion: components[0], minorVersion: components.count > 1 ? components[1] : 0, patchVersion: components.count > 2 ? components[2] : 0)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOS) else { throw UpdateError.invalidBundle }
        let binary = app.appendingPathComponent("Contents/MacOS/Swoosh")
        let arch = try String(decoding: UpdateCommand.run("/usr/bin/lipo", ["-archs", binary.path]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard arch == "arm64" else { throw UpdateError.invalidBundle }
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // Preserve the current signing identity when distributed with a Developer ID.
        func team(_ url: URL) throws -> String? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError.invalidBundle }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let info = information as? [String: Any] else { throw UpdateError.invalidBundle }
            return info[kSecCodeInfoTeamIdentifier as String] as? String
        }
        let currentTeam = try team(installed), nextTeam = try team(app)
        guard currentTeam == nextTeam else { throw UpdateError.invalidBundle }
    }
}
