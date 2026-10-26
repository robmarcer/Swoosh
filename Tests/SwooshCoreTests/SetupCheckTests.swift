import XCTest
@testable import SwooshCore

final class SetupCheckTests: XCTestCase {
    var root: URL!
    var app: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app = root.appendingPathComponent("Library/Orbit/Orbit.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleExecutable": "Orbit", "CFBundleName": "Orbit"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/Orbit")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func inspect() -> [SetupDiagnostic] { SetupCheck.inspect(app: app, libraryRoot: root.appendingPathComponent("Library")) }
    func manifest(_ text: String) throws { try Data(text.utf8).write(to: app.deletingLastPathComponent().appendingPathComponent("SwooshGame.json")) }
    func testUnverifiedDataIsInformationalAndBrokenAppsRemainVisible() throws {
        XCTAssertFalse(inspect().contains { $0.blocksLaunch })
        XCTAssertTrue(inspect().contains { !$0.blocksLaunch })
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Info.plist"))
        let games = Library.scan(root.appendingPathComponent("Library")).games
        XCTAssertEqual(games.count, 1)
        XCTAssertFalse(games[0].canLaunch)
    }
    func testRequiredDataRechecksWithoutRestart() throws {
        try manifest("{\"requiredPaths\":[\"GameData/content\"]}")
        XCTAssertTrue(inspect().contains { $0.blocksLaunch })
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent().appendingPathComponent("GameData/content"), withIntermediateDirectories: true)
        XCTAssertTrue(inspect().isEmpty)
    }
    func testUnsafePathsAndSymlinkEscapeAreRejected() throws {
        for path in ["../outside", "/tmp", "."] { XCTAssertNil(SetupCheck.relativePath(path, beneath: app.deletingLastPathComponent())) }
        let link = app.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertNil(SetupCheck.relativePath("outside", beneath: app.deletingLastPathComponent()))
    }
    func testMalformedManifestAndPermissionsBlockLaunch() throws {
        try manifest("not json")
        XCTAssertTrue(inspect().contains { $0.blocksLaunch })
        try FileManager.default.removeItem(at: app.deletingLastPathComponent().appendingPathComponent("SwooshGame.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/Orbit").path)
        XCTAssertTrue(inspect().contains { $0.blocksLaunch && $0.message.contains("permission") })
    }
}
