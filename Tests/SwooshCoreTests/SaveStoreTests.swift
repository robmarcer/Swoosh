import XCTest
@testable import SwooshCore

final class SaveStoreTests: XCTestCase {
    var root: URL!
    let id = "0100ABCDEF120000"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func source(_ name: String = "runtime/save") throws -> URL {
        let source = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("progress-one".utf8).write(to: source.appendingPathComponent("slot"))
        return source
    }
    func value(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("slot"), encoding: .utf8) }
    var app: URL { root.appendingPathComponent("Library/Orbit/Orbit.app") }
    func testExternalStorageSurvivesRenamingAndReinstallation() async throws {
        let original = try source()
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        let config = SaveConfiguration(mode: .environment, path: original.path, environmentVariable: "DM_SAVE")
        let env = try await store.prepare(titleID: id, app: app, config: config)
        let live = URL(fileURLWithPath: env["DM_SAVE"]!)
        XCTAssertEqual(try value(live), "progress-one")
        try Data("progress-two".utf8).write(to: live.appendingPathComponent("slot"))
        try await store.recover(titleID: id)
        try FileManager.default.removeItem(at: original)
        let next = try await store.prepare(titleID: id, app: root.appendingPathComponent("New/Renamed.app"), config: config)
        XCTAssertEqual(next["DM_SAVE"], live.path)
        XCTAssertEqual(try value(live), "progress-two")
        let summary = try await store.summary(titleID: id)
        XCTAssertEqual(summary.backups.count, 2)
    }
    func testCopySessionRecoversProgressAfterRestartBeforeCopyingIn() async throws {
        let original = try source()
        let managed = root.appendingPathComponent("Managed")
        let config = SaveConfiguration(mode: .copy, path: original.path)
        let store = SaveStore(root: managed)
        _ = try await store.prepare(titleID: id, app: app, config: config)
        try Data("new-progress".utf8).write(to: original.appendingPathComponent("slot"))
        let restarted = SaveStore(root: managed)
        _ = try await restarted.prepare(titleID: id, app: app, config: config)
        XCTAssertEqual(try value(original), "new-progress")
        XCTAssertEqual(try value(managed.appendingPathComponent(id + "/live/save")), "new-progress")
    }
    func testRunningSessionBlocksRecoveryAndRestore() async throws {
        let original = try source()
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .copy, path: original.path))
        do { try await store.recover(titleID: id, activeApps: [app.path]); XCTFail("Recovered running game") } catch SaveError.activeSession {}
    }
    func testConflictingExternalChangesPreserveBothCopies() async throws {
        let original = try source()
        let managed = root.appendingPathComponent("Managed")
        let store = SaveStore(root: managed)
        _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .copy, path: original.path))
        let live = managed.appendingPathComponent(id + "/live/save")
        try Data("external-change".utf8).write(to: live.appendingPathComponent("slot"))
        try Data("game-change".utf8).write(to: original.appendingPathComponent("slot"))
        do { try await store.recover(titleID: id); XCTFail("Replaced conflicting data") } catch SaveError.conflict {}
        XCTAssertEqual(try value(live), "external-change")
        XCTAssertEqual(try value(original), "game-change")
    }
    func testMissingRuntimeAfterInterruptedSessionDoesNotEraseCanonicalSaves() async throws {
        let original = try source()
        let managed = root.appendingPathComponent("Managed")
        let store = SaveStore(root: managed)
        _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .copy, path: original.path))
        try FileManager.default.removeItem(at: original)
        do { try await store.recover(titleID: id); XCTFail("Accepted missing saves") } catch SaveError.conflict {}
        XCTAssertEqual(try value(managed.appendingPathComponent(id + "/live/save")), "progress-one")
    }
    func testRestoreVerifiesBackupAndProtectsCurrentSaves() async throws {
        let original = try source()
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        let env = try await store.prepare(titleID: id, app: app, config: .init(mode: .environment, path: original.path, environmentVariable: "DM_SAVE"))
        try await store.recover(titleID: id)
        let summary = try await store.summary(titleID: id)
        let first = summary.backups[0]
        let live = URL(fileURLWithPath: env["DM_SAVE"]!)
        try Data("later-progress".utf8).write(to: live.appendingPathComponent("slot"))
        try await store.restore(titleID: id, backupID: first.id)
        XCTAssertEqual(try value(live), "progress-one")
        let after = try await store.summary(titleID: id)
        XCTAssertTrue(after.backups.contains { $0.reason == "Before restore" })
        let backupData = summary.location.appendingPathComponent("Backups/" + first.id + "/data/save/slot")
        try Data("corrupted".utf8).write(to: backupData)
        do { try await store.restore(titleID: id, backupID: first.id); XCTFail("Restored corrupt backup") } catch SaveError.invalidBackup {}
        XCTAssertEqual(try value(live), "progress-one")
    }
    func testRetentionAndSeparateTitleIdentities() async throws {
        let original = try source()
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        let config = SaveConfiguration(mode: .environment, path: original.path, environmentVariable: "DM_SAVE")
        _ = try await store.prepare(titleID: id, app: app, config: config)
        try await store.recover(titleID: id)
        try await store.setRetention(titleID: id, count: 5)
        for _ in 0..<8 { _ = try await store.backup(titleID: id, reason: "Test") }
        let summary = try await store.summary(titleID: id)
        XCTAssertEqual(summary.backups.count, 5)
        let other = try await store.prepare(titleID: "0100ABCDEF130000", app: app, config: config)
        XCTAssertFalse(other["DM_SAVE"]!.contains(id))
    }
    func testSymlinkInSaveTreeAndInvalidConfigurationAreRejected() async throws {
        let original = try source()
        try FileManager.default.createSymbolicLink(at: original.appendingPathComponent("escape"), withDestinationURL: root)
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        do { _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .copy, path: original.path)); XCTFail("Copied symlink") } catch SaveError.unsafeTree {}
        do { _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .environment, path: original.path, environmentVariable: "HOME")); XCTFail("Changed HOME") } catch SaveError.invalidConfiguration {}
        do { _ = try await store.prepare(titleID: "Orbit", app: app, config: .init(mode: .copy, path: original.path)); XCTFail("Used name as ID") } catch SaveError.missingIdentity {}
    }
    func testDeviceSavesAreMigratedAndRestoredTogether() async throws {
        let original = try source()
        let device = try source("runtime/save_device")
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        let env = try await store.prepare(titleID: id, app: app, config: .init(mode: .environment, path: original.path, environmentVariable: "DM_SAVE"))
        XCTAssertEqual(try value(URL(fileURLWithPath: env["DM_SAVE"]! + "_device")), try value(device))
        XCTAssertEqual(try value(original), "progress-one") // Migration retains originals.
    }
    func testInterruptedPreparationCannotImportPartialRuntimeData() async throws {
        let original = try source()
        let managed = root.appendingPathComponent("Managed")
        let store = SaveStore(root: managed)
        _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .copy, path: original.path))
        let journal = managed.appendingPathComponent(id + "/session.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
        object["ready"] = false
        try JSONSerialization.data(withJSONObject: object).write(to: journal)
        try Data("partial-copy".utf8).write(to: original.appendingPathComponent("slot"))
        try await store.recover(titleID: id)
        XCTAssertEqual(try value(managed.appendingPathComponent(id + "/live/save")), "progress-one")
    }
    func testManuallyRunningGameBlocksInitialMigration() async throws {
        let original = try source()
        let store = SaveStore(root: root.appendingPathComponent("Managed"))
        do {
            _ = try await store.prepare(titleID: id, app: app, config: .init(mode: .copy, path: original.path), activeApps: [app.path])
            XCTFail("Migrated a running game")
        } catch SaveError.activeSession {}
    }

}
