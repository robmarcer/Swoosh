import XCTest
import AppKit
@testable import Swoosh
import SwooshCore

final class HomeNavigationTests: XCTestCase {
    @MainActor func testHomeLibraryResumeAndSeparateQuitConfirmation() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(library: folder, backgroundServices: false)
        model.running = NSRunningApplication.current
        model.runningName = "Orbit"
        model.requestHome()
        XCTAssertTrue(model.showingHome)
        XCTAssertFalse(model.showingQuit)
        XCTAssertEqual(model.homeFocus, 0)
        model.move(.down); model.confirm()
        XCTAssertFalse(model.showingHome)
        XCTAssertNotNil(model.running)
        model.confirm()
        XCTAssertNotNil(model.issue) // Another game cannot be started.
        model.issue = nil
        model.requestHome(); model.move(.down); model.move(.down); model.confirm()
        XCTAssertTrue(model.showingQuit)
        XCTAssertFalse(model.quitFocused)
        model.back()
        XCTAssertFalse(model.showingQuit)
        XCTAssertTrue(model.showingHome)
        model.finishSession()
        XCTAssertNil(model.running)
        XCTAssertFalse(model.showingHome)
        XCTAssertEqual(model.homeProgress, 0)
    }
    @MainActor func testUpdateReviewDefaultsToCancelAndBlocksDuringGame() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(library: folder, backgroundServices: false)
        model.launcherRelease = try JSONDecoder().decode(LauncherRelease.self, from: Data("{\"tag_name\":\"v0.9.0\",\"draft\":false,\"prerelease\":true,\"assets\":[]}".utf8))
        model.running = NSRunningApplication.current
        model.reviewLauncherUpdate()
        XCTAssertFalse(model.showingUpdate)
        XCTAssertNotNil(model.issue)
        model.running = nil; model.issue = nil
        model.reviewLauncherUpdate()
        XCTAssertTrue(model.showingUpdate)
        XCTAssertFalse(model.installFocused)
        model.confirm()
        XCTAssertFalse(model.showingUpdate)
        XCTAssertFalse(model.updatingLauncher)
    }

}
