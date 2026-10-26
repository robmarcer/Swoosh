import XCTest
@testable import SwooshCore

final class LauncherUpdateTests: XCTestCase {
    func testSemanticVersionsAndPrereleaseOrdering() {
        XCTAssertLessThan(LauncherVersion("0.9.0")!, LauncherVersion("0.10.0")!)
        XCTAssertLessThan(LauncherVersion("1.0.0-rc.2")!, LauncherVersion("1.0.0-rc.10")!)
        XCTAssertLessThan(LauncherVersion("1.0.0-rc.10")!, LauncherVersion("1.0.0")!)
        XCTAssertEqual(LauncherVersion("v1.2.3+build.2"), LauncherVersion("1.2.3"))
        for invalid in ["latest", "1.0", "01.2.3", "1.0.0-01", "1.0.0;echo", "../../1.0.0"] { XCTAssertNil(LauncherVersion(invalid)) }
    }
    func feed() throws -> Data {
        func release(_ version: String, preview: Bool = false, draft: Bool = false, archive: Bool = true) -> [String: Any] {
            ["tag_name": "v" + version, "body": "Release notes", "draft": draft, "prerelease": preview,
             "assets": archive ? [["name": "Swoosh-" + version + "-macos-arm64.zip", "size": 100], ["name": "SHA256SUMS.txt", "size": 95]] : []]
        }
        return try JSONSerialization.data(withJSONObject: [release("0.4.0"), release("0.5.0", preview: true), release("0.6.0", draft: true), release("0.7.0", archive: false)])
    }
    func testChannelFilteringRejectsDraftMissingAssetsAndDowngrades() throws {
        XCTAssertEqual(try LauncherRelease.newest(in: feed(), installed: "0.3.0", includePrereleases: false)?.tag_name, "v0.4.0")
        XCTAssertEqual(try LauncherRelease.newest(in: feed(), installed: "0.4.0", includePrereleases: true)?.tag_name, "v0.5.0")
        XCTAssertNil(try LauncherRelease.newest(in: feed(), installed: "0.5.0", includePrereleases: true))
        XCTAssertNil(try LauncherRelease.newest(in: feed(), installed: "0.8.0", includePrereleases: true))
    }
    func testChecksumsRequireUniqueExactAssetName() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdateValidation.checksum(hash + "  Swoosh.zip\n", filename: "Swoosh.zip"), hash)
        XCTAssertNil(UpdateValidation.checksum(hash + "  Other.zip", filename: "Swoosh.zip"))
        XCTAssertNil(UpdateValidation.checksum(hash + "  Swoosh.zip\n" + hash + "  Swoosh.zip", filename: "Swoosh.zip"))
        XCTAssertNil(UpdateValidation.checksum("bad  Swoosh.zip", filename: "Swoosh.zip"))
    }
    func testArchivePathsCannotEscapeBundle() {
        XCTAssertTrue(UpdateValidation.validArchivePaths("Swoosh.app/\nSwoosh.app/Contents/MacOS/Swoosh\n"))
        for path in ["/Swoosh.app/a", "Swoosh.app/../outside", "Other.app/Contents/a", "Swoosh.app/Contents/../../a", ""] { XCTAssertFalse(UpdateValidation.validArchivePaths(path)) }
    }
    func testFailedAtomicExchangeKeepsInstalledApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installed = root.appendingPathComponent("Swoosh.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        XCTAssertThrowsError(try UpdateInstaller.exchange(staged: root.appendingPathComponent("missing.app"), installed: installed))
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker")), "old")
    }
}

final class UpdateInstallerTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func app(_ name: String, version: String, identifier: String = "dev.swoosh.launcher") throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent(UUID().uuidString + ".c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        _ = try UpdateCommand.run("/usr/bin/clang", ["-arch", "arm64", "-mmacosx-version-min=14.0", source.path, "-o", app.appendingPathComponent("Contents/MacOS/Swoosh").path])
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Swoosh", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }
    func testBundleValidationAcceptsSignedArm64AndRejectsWrongIdentityOrVersion() throws {
        let installed = try app("Installed.app", version: "0.1.0")
        let next = try app("Swoosh.app", version: "0.2.0")
        XCTAssertNoThrow(try UpdateValidation.validateBundle(next, expectedVersion: "v0.2.0", installed: installed))
        XCTAssertThrowsError(try UpdateValidation.validateBundle(next, expectedVersion: "v0.3.0", installed: installed))
        let unrelated = try app("Other.app", version: "0.2.0", identifier: "invalid.other")
        XCTAssertThrowsError(try UpdateValidation.validateBundle(unrelated, expectedVersion: "v0.2.0", installed: installed))
        try Data("tampered".utf8).write(to: next.appendingPathComponent("Contents/MacOS/Swoosh"))
        XCTAssertThrowsError(try UpdateValidation.validateBundle(next, expectedVersion: "v0.2.0", installed: installed))
    }
    func testStageAndRollbackLeavePreviousAppRecoverable() throws {
        let installed = try app("Installed.app", version: "0.1.0")
        let next = try app("Swoosh.app", version: "0.2.0")
        let archive = root.appendingPathComponent("release.zip")
        _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", next.path, archive.path])
        let release = try JSONDecoder().decode(LauncherRelease.self, from: Data("{\"tag_name\":\"v0.2.0\",\"draft\":false,\"prerelease\":true,\"assets\":[]}".utf8))
        let workspace = root.appendingPathComponent("work")
        let plan = try UpdateInstaller.stage(archive: archive, release: release, installed: installed, workspace: workspace)
        XCTAssertEqual(Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.1.0")
        // A receipt-write failure after the atomic exchange must roll the installation back.
        let failing = UpdateInstallPlan(installed: plan.installed, staged: plan.staged, version: plan.version, parentPID: Int32.max, executableDigest: plan.executableDigest, receipt: root.appendingPathComponent("missing/receipt.json"))
        let planURL = workspace.appendingPathComponent("plan.json")
        try JSONEncoder().encode(failing).write(to: planURL)
        XCTAssertThrowsError(try UpdateInstaller.finish(planURL: planURL))
        XCTAssertNoThrow(try UpdateValidation.validateBundle(installed, expectedVersion: "0.1.0", installed: installed))
        let info = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        let object = try PropertyListSerialization.propertyList(from: info, format: nil) as! [String: Any]
        XCTAssertEqual(object["CFBundleShortVersionString"] as? String, "0.1.0")
    }
    func testArchiveSymlinksAreRejectedBeforeExtraction() throws {
        let installed = try app("Installed.app", version: "0.1.0")
        let next = try app("Swoosh.app", version: "0.2.0")
        try FileManager.default.createSymbolicLink(at: next.appendingPathComponent("escape"), withDestinationURL: root)
        let archive = root.appendingPathComponent("release.zip")
        _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", next.path, archive.path])
        let release = try JSONDecoder().decode(LauncherRelease.self, from: Data("{\"tag_name\":\"v0.2.0\",\"draft\":false,\"prerelease\":true,\"assets\":[]}".utf8))
        XCTAssertThrowsError(try UpdateInstaller.stage(archive: archive, release: release, installed: installed, workspace: root.appendingPathComponent("work")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work/extracted").path))
    }
}
