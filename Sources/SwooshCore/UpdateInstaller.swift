import Foundation
import Darwin

public struct UpdateInstallPlan: Codable, Sendable {
    public let installed: URL
    public let staged: URL
    public let version: String
    public let parentPID: Int32
    public let executableDigest: String
    public let receipt: URL
}

public enum UpdateInstaller {
    public static func stage(archive: URL, release: LauncherRelease, installed: URL, workspace: URL) throws -> UpdateInstallPlan {
        let fm = FileManager.default
        let parent = installed.deletingLastPathComponent()
        guard installed.pathExtension == "app", !installed.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: parent.path) else { throw UpdateError.permissions }
        let paths = try String(decoding: UpdateCommand.run("/usr/bin/zipinfo", ["-1", archive.path]), as: UTF8.self)
        guard UpdateValidation.validArchivePaths(paths) else { throw UpdateError.invalidBundle }
        let listing = try String(decoding: UpdateCommand.run("/usr/bin/zipinfo", ["-l", archive.path]), as: UTF8.self)
        let entries = listing.components(separatedBy: .newlines).filter { $0.hasPrefix("-") || $0.hasPrefix("d") || $0.hasPrefix("l") }
        var total: Int64 = 0
        for entry in entries {
            let fields = entry.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard !entry.hasPrefix("l"), fields.count >= 9, let size = Int64(fields[3]), size >= 0, size <= 200_000_000 else { throw UpdateError.invalidBundle }
            total += size
        }
        guard !entries.isEmpty, entries.count == paths.components(separatedBy: .newlines).filter({ !$0.isEmpty }).count, total <= 500_000_000 else { throw UpdateError.invalidBundle }
        let extraction = workspace.appendingPathComponent("extracted")
        try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
        _ = try UpdateCommand.run("/usr/bin/ditto", ["-x", "-k", archive.path, extraction.path])
        let app = extraction.appendingPathComponent("Swoosh.app")
        try UpdateValidation.validateBundle(app, expectedVersion: release.tag_name, installed: installed)
        guard let current = Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let currentVersion = LauncherVersion(current), let next = LauncherVersion(release.tag_name), next > currentVersion else { throw UpdateError.invalidRelease }
        let staged = parent.appendingPathComponent(".Swoosh-update-" + UUID().uuidString + ".app")
        try fm.copyItem(at: app, to: staged)
        try UpdateValidation.validateBundle(staged, expectedVersion: release.tag_name, installed: installed)
        let receipt = workspace.appendingPathComponent("receipt.json")
        return UpdateInstallPlan(installed: installed, staged: staged, version: release.tag_name, parentPID: ProcessInfo.processInfo.processIdentifier,
                                 executableDigest: try UpdateValidation.sha256(staged.appendingPathComponent("Contents/MacOS/Swoosh")), receipt: receipt)
    }

    /// Atomic exchange leaves the previous app at staged for recovery. A failed swap changes neither app.
    public static func exchange(staged: URL, installed: URL) throws {
        guard staged.deletingLastPathComponent() == installed.deletingLastPathComponent(), staged != installed else { throw UpdateError.permissions }
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateError.permissions }
    }

    public static func recoverFailedPlan(_ planURL: URL) {
        guard let data = try? Data(contentsOf: planURL), let plan = try? JSONDecoder().decode(UpdateInstallPlan.self, from: data),
              let version = Bundle(url: plan.installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              (try? UpdateValidation.validateBundle(plan.installed, expectedVersion: version, installed: plan.installed)) != nil else { return }
        try? Data("Update did not complete. The installed app was retained; use Settings to retry or download manually.".utf8).write(to: planURL.deletingLastPathComponent().appendingPathComponent("failure.txt"), options: .atomic)
        _ = try? UpdateCommand.run("/usr/bin/open", [plan.installed.path], timeout: 20)
    }

    public static func finish(planURL: URL, relaunch: ((URL) throws -> Void)? = nil) throws {
        func open(_ app: URL) throws {
            if let relaunch { try relaunch(app) }
            else { _ = try UpdateCommand.run("/usr/bin/open", [app.path], timeout: 20) }
        }
        let fm = FileManager.default
        let plan = try JSONDecoder().decode(UpdateInstallPlan.self, from: Data(contentsOf: planURL))
        guard plan.staged.deletingLastPathComponent() == plan.installed.deletingLastPathComponent(),
              plan.staged.lastPathComponent.hasPrefix(".Swoosh-update-"), plan.staged.pathExtension == "app", plan.installed.pathExtension == "app",
              try UpdateValidation.sha256(plan.staged.appendingPathComponent("Contents/MacOS/Swoosh")) == plan.executableDigest else { throw UpdateError.invalidBundle }
        try UpdateValidation.validateBundle(plan.staged, expectedVersion: plan.version, installed: plan.installed)
        let deadline = Date().addingTimeInterval(60)
        while kill(plan.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard kill(plan.parentPID, 0) != 0 else { throw UpdateError.parentStillRunning }
        try exchange(staged: plan.staged, installed: plan.installed)
        do {
            try UpdateValidation.validateBundle(plan.installed, expectedVersion: plan.version, installed: plan.staged)
            try JSONEncoder().encode(plan).write(to: plan.receipt, options: .atomic)
            try open(plan.installed)
        } catch {
            // Roll back if verification, receipt writing or relaunch fails.
            try exchange(staged: plan.staged, installed: plan.installed)
            try? open(plan.installed)
            throw error
        }
        // Keep the previous app beside the installation until a later cleanup policy is introduced.
        try? fm.removeItem(at: planURL)
    }
}
