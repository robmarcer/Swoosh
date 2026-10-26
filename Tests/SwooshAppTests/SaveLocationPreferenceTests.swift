import XCTest
import AppKit
@testable import Swoosh

final class SaveLocationPreferenceTests: XCTestCase {
    func testSelectedFolderPersistsAndFollowsRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Chosen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saves = folder.appendingPathComponent("Swoosh Saves")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: saves.appendingPathComponent("marker"))
        let preference = try SaveLocationPreference(selected: folder)
        let suite = "dev.swoosh.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(preference), forKey: SaveLocationPreference.key)
        XCTAssertEqual(try String(contentsOf: SaveLocationPreference.load(defaults)!.resolve().appendingPathComponent("marker")), "marker")
        let renamed = root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: folder, to: renamed)
        let restored = SaveLocationPreference.load(defaults)!.resolve()
        XCTAssertEqual(restored.deletingLastPathComponent().lastPathComponent, "Renamed")
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("marker")), "marker")
    }
    @MainActor func testChangingLocationIsBlockedWhileGameRuns() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "dev.swoosh.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(library: root, backgroundServices: false, savePreferences: defaults)
        model.running = NSRunningApplication.current
        model.changeSaveLocation(selected: root)
        XCTAssertNotNil(model.issue)
        XCTAssertNil(defaults.data(forKey: SaveLocationPreference.key))
        XCTAssertFalse(model.saving)
    }
}
