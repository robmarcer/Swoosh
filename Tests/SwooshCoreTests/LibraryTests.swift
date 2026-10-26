import XCTest
@testable import SwooshCore

final class LibraryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func app(_ path: String, name: String, executable: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleName": name, "CFBundleExecutable": "Game"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let binary = url.appendingPathComponent("Contents/MacOS/Game")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path)
        return url
    }

    func testRealisticLayoutsIgnoreDataAndUnconvertedFiles() throws {
        try app("Orbit/Game.app", name: "Orbit")
        try app("Aurora.app", name: "Aurora")
        try app("Orbit/GameData/tools/Helper.app", name: "Not a game")
        try app("Broken.app", name: "Broken", executable: false)
        try app(".Hidden.app", name: "Hidden")
        try Data().write(to: root.appendingPathComponent("Other.nsp"))
        let result = Library.scan(root)
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.games.map(\.name), ["Aurora", "Broken", "Orbit"])
        XCTAssertFalse(result.games.first { $0.name == "Broken" }!.canLaunch)
    }

    func testRefreshReflectsAddsAndRemovals() throws {
        XCTAssertTrue(Library.scan(root).games.isEmpty)
        let game = try app("Aurora/Aurora.app", name: "Aurora")
        XCTAssertEqual(Library.scan(root).games.count, 1)
        try FileManager.default.removeItem(at: game)
        XCTAssertTrue(Library.scan(root).games.isEmpty)
    }

    func testAliasesDeduplicateAndCoverIsScopedToGameFolder() throws {
        let game = try app("Aurora/Aurora.app", name: "Aurora")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: game)
        try Data().write(to: root.appendingPathComponent("cover.jpg"))
        XCTAssertEqual(Library.scan(root).games.count, 1)
        XCTAssertNil(Library.scan(root).games.first?.coverURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Alias.app"))
        let cover = root.appendingPathComponent("Aurora/cover.png")
        try Data().write(to: cover)
        XCTAssertEqual(Library.scan(root).games.first?.coverURL?.resolvingSymlinksInPath(), cover.resolvingSymlinksInPath())
        try app("TopLevel.app", name: "Top level")
        XCTAssertNil(Library.scan(root).games.first { $0.name == "Top level" }?.coverURL)
    }

    func testMissingFolderReportsAnIssue() {
        XCTAssertNotNil(Library.scan(root.appendingPathComponent("missing")).issue)
    }

    func testGridEdgesAndIncompleteLastRow() {
        XCTAssertEqual(GridNavigation.next(3, direction: .right, count: 6, columns: 4), 3)
        XCTAssertEqual(GridNavigation.next(4, direction: .left, count: 6, columns: 4), 4)
        XCTAssertEqual(GridNavigation.next(1, direction: .down, count: 6, columns: 4), 5)
        XCTAssertEqual(GridNavigation.next(2, direction: .down, count: 6, columns: 4), 2)
        XCTAssertEqual(GridNavigation.next(5, direction: .up, count: 6, columns: 4), 1)
        XCTAssertEqual(GridNavigation.next(0, direction: .down, count: 0, columns: 4), 0)
    }
}
