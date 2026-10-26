import XCTest
@testable import SwooshCore

final class SaveLocationTests: XCTestCase {
    var root: URL!
    let id = "0100ABCDEF120000"
    var app: URL { root.appendingPathComponent("Library/Orbit.app") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func initial(_ sourceName: String = "runtime/save") throws -> SaveConfiguration {
        let source = root.appendingPathComponent(sourceName)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source.appendingPathComponent("slot"))
        return SaveConfiguration(mode: .environment, path: source.path, environmentVariable: "DM_SAVE")
    }
    func text(_ folder: URL) throws -> String { try String(contentsOf: folder.appendingPathComponent("slot"), encoding: .utf8) }
    func testMigrationKeepsOriginalAndCopiesBackupsAndSaves() async throws {
        let original = root.appendingPathComponent("Original")
        let store = SaveStore(root: original)
        _ = try await store.prepare(titleID: id, app: app, config: initial())
        try await store.recover(titleID: id)
        let target = root.appendingPathComponent("Shared/Swoosh Saves")
        try await store.changeLocation(to: target, sessionRoot: root.appendingPathComponent("Sessions"))
        XCTAssertEqual(try text(target.appendingPathComponent(id + "/live/save")), "first")
        XCTAssertEqual(try text(original.appendingPathComponent(id + "/live/save")), "first")
        let summary = try await store.summary(titleID: id)
        XCTAssertEqual(summary.backups.count, 1)
        XCTAssertEqual(summary.location.resolvingSymlinksInPath(), target.appendingPathComponent(id).resolvingSymlinksInPath())
    }
    func testCustomStorageUsesLocalWorkingSavesAndRecoversAfterRestart() async throws {
        let selected = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("LocalSessions")
        let config = try initial()
        let store = SaveStore(root: selected, sessionRoot: sessions, requiresExistingRoot: true)
        let env = try await store.prepare(titleID: id, app: app, config: config)
        let working = URL(fileURLWithPath: env["DM_SAVE"]!)
        XCTAssertTrue(working.path.hasPrefix(sessions.path))
        XCTAssertFalse(working.path.hasPrefix(selected.path))
        try Data("new-progress".utf8).write(to: working.appendingPathComponent("slot"))
        let scratch = URL(fileURLWithPath: working.path + ".work")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("uncommitted".utf8).write(to: scratch.appendingPathComponent("temporary"))
        XCTAssertEqual(try text(selected.appendingPathComponent(id + "/live/save")), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.appendingPathComponent(id + "/session.json").path))
        let restarted = SaveStore(root: selected, sessionRoot: sessions, requiresExistingRoot: true)
        try await restarted.recover(titleID: id)
        XCTAssertEqual(try text(selected.appendingPathComponent(id + "/live/save")), "new-progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.appendingPathComponent(id + "/live/save.work").path))
    }
    func testCloudConflictPreservesRemoteAndLocalProgress() async throws {
        let selected = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("Sessions")
        let store = SaveStore(root: selected, sessionRoot: sessions, requiresExistingRoot: true)
        let env = try await store.prepare(titleID: id, app: app, config: initial())
        let working = URL(fileURLWithPath: env["DM_SAVE"]!)
        let remote = selected.appendingPathComponent(id + "/live/save")
        try Data("this-mac".utf8).write(to: working.appendingPathComponent("slot"))
        try Data("other-mac".utf8).write(to: remote.appendingPathComponent("slot"))
        do { try await store.recover(titleID: id); XCTFail("Overwrote conflict") } catch SaveError.conflict {}
        XCTAssertEqual(try text(remote), "other-mac")
        XCTAssertEqual(try text(working), "this-mac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent(id + "/session.json").path))
    }
    func testUnavailableSelectedFolderNeverCreatesAnEmptyReplacement() async throws {
        let selected = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("Sessions")
        let store = SaveStore(root: selected, sessionRoot: sessions, requiresExistingRoot: true)
        let env = try await store.prepare(titleID: id, app: app, config: initial())
        try Data("offline-progress".utf8).write(to: URL(fileURLWithPath: env["DM_SAVE"]!).appendingPathComponent("slot"))
        let disconnected = root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: selected, to: disconnected)
        do { try await store.recover(titleID: id); XCTFail("Accepted unavailable location") } catch SaveError.storageUnavailable {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        try FileManager.default.moveItem(at: disconnected, to: selected)
        try await store.recover(titleID: id)
        XCTAssertEqual(try text(selected.appendingPathComponent(id + "/live/save")), "offline-progress")
    }
    func testConflictingMigrationDoesNotChangeEitherRoot() async throws {
        let oldRoot = root.appendingPathComponent("Original"), destination = root.appendingPathComponent("Destination")
        let store = SaveStore(root: oldRoot), other = SaveStore(root: destination)
        _ = try await store.prepare(titleID: id, app: app, config: initial())
        try await store.recover(titleID: id)
        let config = try initial("other/save")
        _ = try await other.prepare(titleID: id, app: app, config: config)
        try await other.recover(titleID: id)
        let remote = destination.appendingPathComponent(id + "/live/save")
        try Data("different".utf8).write(to: remote.appendingPathComponent("slot"))
        do { try await store.changeLocation(to: destination, sessionRoot: nil); XCTFail("Overwrote destination") } catch SaveError.locationConflict {}
        XCTAssertEqual(try text(remote), "different")
        XCTAssertEqual(try text(oldRoot.appendingPathComponent(id + "/live/save")), "first")
        let current = await store.root
        XCTAssertEqual(current, oldRoot)
    }
    func testEmptyInstallationCanReconnectExistingStorage() async throws {
        let destination = root.appendingPathComponent("Existing")
        let original = SaveStore(root: destination)
        _ = try await original.prepare(titleID: id, app: app, config: initial())
        try await original.recover(titleID: id)
        let fresh = SaveStore(root: root.appendingPathComponent("Fresh"))
        try await fresh.changeLocation(to: destination, sessionRoot: root.appendingPathComponent("Sessions"))
        let summary = try await fresh.summary(titleID: id)
        XCTAssertEqual(summary.backups.count, 1)
        XCTAssertEqual(try text(destination.appendingPathComponent(id + "/live/save")), "first")
    }
    func testPendingCopySessionIsRecoveredBeforeMigrationAndRunningGameBlocksIt() async throws {
        let config = try initial()
        let copyConfig = SaveConfiguration(mode: .copy, path: config.path)
        let store = SaveStore(root: root.appendingPathComponent("Original"))
        _ = try await store.prepare(titleID: id, app: app, config: copyConfig)
        try Data("pending-progress".utf8).write(to: URL(fileURLWithPath: config.path).appendingPathComponent("slot"))
        let destination = root.appendingPathComponent("Destination")
        do { try await store.changeLocation(to: destination, sessionRoot: nil, activeApps: [app.path]); XCTFail("Migrated running saves") } catch SaveError.activeSession {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await store.changeLocation(to: destination, sessionRoot: root.appendingPathComponent("Sessions"))
        XCTAssertEqual(try text(destination.appendingPathComponent(id + "/live/save")), "pending-progress")
    }
    func testNestedAndGameLibraryLocationsAreRejected() async throws {
        let original = root.appendingPathComponent("Original")
        let store = SaveStore(root: original)
        do { try await store.changeLocation(to: original.appendingPathComponent("Nested"), sessionRoot: nil); XCTFail("Nested storage") } catch SaveError.unsafeTree {}
        let library = root.appendingPathComponent("Library")
        do { try await store.changeLocation(to: library.appendingPathComponent("Saves"), sessionRoot: nil, forbiddenRoots: [library]); XCTFail("Storage inside games") } catch SaveError.unsafeTree {}
    }
    func testRecoveryIsIdempotentAfterPublishBeforeJournalCleanup() async throws {
        let selected = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let store = SaveStore(root: selected, sessionRoot: root.appendingPathComponent("Sessions"), requiresExistingRoot: true)
        let env = try await store.prepare(titleID: id, app: app, config: initial())
        let working = URL(fileURLWithPath: env["DM_SAVE"]!)
        try Data("published".utf8).write(to: working.appendingPathComponent("slot"))
        try Data("published".utf8).write(to: selected.appendingPathComponent(id + "/live/save/slot"))
        try await store.recover(titleID: id)
        try await store.recover(titleID: id)
        XCTAssertEqual(try text(selected.appendingPathComponent(id + "/live/save")), "published")
    }
    func testCopyRuntimeWithCustomStoragePublishesAfterExit() async throws {
        let config = try initial()
        let selected = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let store = SaveStore(root: selected, sessionRoot: root.appendingPathComponent("Sessions"), requiresExistingRoot: true)
        let copy = SaveConfiguration(mode: .copy, path: config.path)
        _ = try await store.prepare(titleID: id, app: app, config: copy)
        try Data("runtime-progress".utf8).write(to: URL(fileURLWithPath: config.path).appendingPathComponent("slot"))
        try await store.recover(titleID: id)
        XCTAssertEqual(try text(selected.appendingPathComponent(id + "/live/save")), "runtime-progress")
    }

}
