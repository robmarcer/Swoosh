import XCTest
import AppKit
@testable import Swoosh
@testable import SwooshCore

private final class SetupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let titleID = "0100ABCDEF345600"
    let stateName = "SwooshTest-" + UUID().uuidString
    var source: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative/" + stateName + "/save") }
    var app: URL { root.appendingPathComponent("Library/Orbit/Orbit.app") }
    var executable: URL { app.appendingPathComponent("Contents/MacOS/Game") }
    var metadata: URL { app.deletingLastPathComponent().appendingPathComponent("SwooshGame.json") }
    init() throws {
        let fm = FileManager.default
        for path in ["Library/Orbit/Orbit.app/Contents/MacOS", "Library/Orbit/GameData/extract/v0/RomFS", "Library/Orbit/GameData/patched_v0", "Library/Orbit/GameData/profile/" + titleID, "Storage/Swoosh Saves"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original-progress".utf8).write(to: source.appendingPathComponent("slot"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable":"Game", "CFBundleName":"Orbit", "CFBundleIdentifier":"dev.swoosh.tests.fixture"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions:0o755], ofItemAtPath: executable.path)
        let profile = app.deletingLastPathComponent().appendingPathComponent("GameData/profile/" + titleID)
        try "title_id\t\(titleID)\npackage\tv0\nbuild\tv0\t1.0.0\n".write(to: profile.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try Data().write(to: profile.appendingPathComponent("shader_map.tsv"))
        try JSONSerialization.data(withJSONObject: ["titleID":titleID,"contentVersion":0,"displayVersion":"1.0.0"]).write(to: metadata)
    }
    deinit { UserDefaults.standard.removePersistentDomain(forName: "dev.swoosh.setup.tests." + root.lastPathComponent); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var script: String {
        #"""
        #!/bin/sh
        set -eu
        APP_CONTENTS="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
        export DM_ROOT="$(CDPATH= cd -- "$APP_CONTENTS/../../GameData" && pwd)"
        STATE_DIR="$HOME/Library/Application Support/nxnative/\#(stateName)"
        export DM_ROMFS="$DM_ROOT/extract/v0/RomFS"
        export DM_SAVE="$STATE_DIR/save"
        export DM_TEMP="$STATE_DIR/temp"
        export DM_MSL_DIR="$DM_ROOT/shader/cache"
        export DM_FONT_DIR="$DM_ROOT/font"
        export DM_NVN_SHMAP="$DM_ROOT/profile/\#(titleID)/shader_map.tsv"
        export DM_LANG=en-US DM_WINDOW=1 DM_AUDIO=1
        mkdir -p "$DM_SAVE" "$DM_TEMP"
        cd "$STATE_DIR"
        exec "$APP_CONTENTS/MacOS/dmhost" "$DM_ROOT/patched_v0" > "$STATE_DIR/launcher.log" 2>&1

        """#
    }
    @MainActor func model() throws -> AppModel {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "dev.swoosh.setup.tests." + root.lastPathComponent)!
        let preference = try SaveLocationPreference(selected: root.appendingPathComponent("Storage"))
        defaults.set(try JSONEncoder().encode(preference), forKey: SaveLocationPreference.key)
        return AppModel(library: root.appendingPathComponent("Library"), backgroundServices: false, savePreferences: defaults,
                        setupStore: GameSetupStore(root: root.appendingPathComponent("Config")), saveSessionRoot: root.appendingPathComponent("Sessions"))
    }
}

final class GameSetupTests: XCTestCase {
    func testImportPersistsAndRejectsDuplicatesInvalidAppsAndSwoosh() throws {
        let f = try SetupFixture(), store = GameSetupStore(root: f.root.appendingPathComponent("Config"))
        try store.register(app: f.app, titleID: nil, imported: true)
        let restored = try GameSetupStore(root: store.root).games(discovered: [], libraryRoot: f.root)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.titleID, f.titleID)
        XCTAssertThrowsError(try store.register(app: f.app, titleID: nil, imported: true, existing: restored))
        XCTAssertThrowsError(try store.register(app: f.root.appendingPathComponent("Missing.app"), titleID: nil, imported: true))
        let plist = f.app.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable":"Game","CFBundleIdentifier":"dev.swoosh.launcher"], format: .xml, options: 0).write(to: plist)
        XCTAssertThrowsError(try store.register(app: f.app, titleID: nil, imported: true))
    }
    func testUnknownIdentityDoesNotInventVersionOrUseSharedSiblingMetadata() throws {
        let f = try SetupFixture(), store = GameSetupStore(root: f.root.appendingPathComponent("Config"))
        let shared = f.root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let moved = shared.appendingPathComponent("Orbit.app")
        try FileManager.default.copyItem(at: f.app, to: moved)
        try FileManager.default.copyItem(at: f.metadata, to: shared.appendingPathComponent("SwooshGame.json"))
        try store.register(app: moved, titleID: nil, imported: true)
        var games = try store.games(discovered: [], libraryRoot: f.root)
        XCTAssertNil(games.first?.titleID)
        XCTAssertNil(games.first?.installedVersion)
        try store.register(app: moved, titleID: f.titleID, imported: false)
        games = try store.games(discovered: [], libraryRoot: f.root)
        XCTAssertEqual(games.first?.titleID, f.titleID)
        XCTAssertNil(games.first?.installedVersion)
        XCTAssertThrowsError(try store.register(app: f.app, titleID: "0100000000000002", imported: false))
        XCTAssertThrowsError(try store.register(app: moved, titleID: "Orbit", imported: false))
    }
    func testCorruptRegistryIsNotOverwritten() throws {
        let f = try SetupFixture(), store = GameSetupStore(root: f.root.appendingPathComponent("Config"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let url = store.root.appendingPathComponent("library.json")
        let original = Data("broken-json".utf8); try original.write(to: url)
        XCTAssertThrowsError(try store.register(app: f.app, titleID: nil, imported: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testWrapperRepairIsNarrowReversibleAndRefusesChangedOrSignedInstallations() throws {
        let f = try SetupFixture()
        let assessment = try XCTUnwrap(NXnativeSetup.assess(app: f.app, titleID: f.titleID))
        XCTAssertFalse(assessment.preservesSaveVariable)
        let backup = try XCTUnwrap(NXnativeSetup.repair(assessment, backupRoot: f.root.appendingPathComponent("Backups")))
        XCTAssertEqual(try String(contentsOf: backup), f.script)
        XCTAssertTrue(try XCTUnwrap(NXnativeSetup.assess(app: f.app, titleID: f.titleID)).preservesSaveVariable)
        try NXnativeSetup.undoRepair(assessment)
        XCTAssertEqual(try String(contentsOf: f.executable), f.script)
        try (f.script + "echo changed\n").write(to: f.executable, atomically: true, encoding: .utf8)
        XCTAssertNil(NXnativeSetup.assess(app: f.app, titleID: f.titleID))
        XCTAssertThrowsError(try NXnativeSetup.repair(assessment, backupRoot: f.root))
        try f.script.write(to: f.executable, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.app.appendingPathComponent("Contents/_CodeSignature"), withIntermediateDirectories: true)
        let signed = try XCTUnwrap(NXnativeSetup.assess(app: f.app, titleID: f.titleID))
        XCTAssertFalse(signed.canRepair)
        XCTAssertThrowsError(try NXnativeSetup.repair(signed, backupRoot: f.root))
    }
    @MainActor func testGuidedProtectionMigratesRetainsOriginalAndRevalidatesAfterUpdate() async throws {
        let f = try SetupFixture(), model = try f.model()
        model.setupTitleID = f.titleID; model.openSaveSetup()
        XCTAssertTrue(model.showingSaveSetup)
        try await model.configureProtection()
        XCTAssertFalse(model.showingSaveSetup)
        XCTAssertEqual(model.protectionStatus(try XCTUnwrap(model.selected)), "Protected saves")
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("slot")), "original-progress")
        XCTAssertEqual(try String(contentsOf: model.saveLocation.appendingPathComponent(f.titleID + "/live/save/slot")), "original-progress")
        let summary = try await model.saveStore.summary(titleID: f.titleID)
        XCTAssertEqual(summary.backups.count, 1)
        let game = try XCTUnwrap(model.selected)
        XCTAssertNotNil(try model.setupStore.configuration(game: game, libraryRoot: model.folder))
        try f.script.write(to: f.executable, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try model.setupStore.configuration(game: game, libraryRoot: model.folder))
        XCTAssertTrue(model.protectionStatus(game).hasPrefix("Incomplete"))
    }
    @MainActor func testMigrationFailureKeepsOriginalAndRollsBackOnlyOwnRepair() async throws {
        let f = try SetupFixture(), model = try f.model()
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("unsafe"), withDestinationURL: f.executable)
        model.setupTitleID = f.titleID; model.openSaveSetup()
        do { try await model.configureProtection(); XCTFail("Unsafe saves accepted") } catch { }
        XCTAssertEqual(try String(contentsOf: f.executable), f.script)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("slot")), "original-progress")
        XCTAssertNil(try model.setupStore.settings(titleID: f.titleID))
        XCTAssertFalse(model.saving)
    }
    @MainActor func testExplicitCopyModePersistsAcrossReinstallAndBlocksUnsafeOrActiveSetup() async throws {
        let f = try SetupFixture(), model = try f.model()
        model.setupTitleID = f.titleID; model.setupSaveSource = f.source; model.setupUsesCopy = true
        try await model.configureProtection()
        let renamed = f.app.deletingLastPathComponent().appendingPathComponent("Renamed.app")
        try FileManager.default.moveItem(at: f.app, to: renamed)
        let game = try XCTUnwrap(Library.inspect(app: renamed, libraryRoot: model.folder))
        let restored = GameSetupStore(root: model.setupStore.root)
        XCTAssertEqual(try restored.configuration(game: game, libraryRoot: model.folder)?.mode, .copy)
        model.refresh(); model.selectedID = game.id
        model.setupSaveSource = model.saveLocation
        do { try await model.configureProtection(); XCTFail("Unsafe path accepted") } catch { }
        model.setupSaveSource = f.source; model.running = NSRunningApplication.current
        do { try await model.configureProtection(); XCTFail("Active game accepted") } catch { }
    }

    @MainActor func testConflictingSetupStopsBeforeRepairAndPreservesBothSaveSets() async throws {
        let f = try SetupFixture(), model = try f.model()
        model.setupTitleID = f.titleID; model.setupSaveSource = f.source; model.setupUsesCopy = true
        try await model.configureProtection()
        try Data("different-local-progress".utf8).write(to: f.source.appendingPathComponent("slot"))
        model.setupUsesCopy = false
        do { try await model.configureProtection(); XCTFail("Conflicting saves accepted") } catch { }
        XCTAssertEqual(try String(contentsOf: f.executable), f.script)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("slot")), "different-local-progress")
        XCTAssertEqual(try String(contentsOf: model.saveLocation.appendingPathComponent(f.titleID + "/live/save/slot")), "original-progress")
    }
    @MainActor func testDetectedIdentityTakesEffectWhenMetadataArrivesDuringSetup() async throws {
        let f = try SetupFixture(), model = try f.model()
        model.setupTitleID = ""
        model.openSaveSetup()
        XCTAssertTrue(model.showingSaveSetup)
        XCTAssertEqual(model.reviewedTitleID, f.titleID)
        try await model.configureProtection()
        XCTAssertNotNil(try model.setupStore.settings(titleID: f.titleID))
    }
    @MainActor func testGuidedNavigationSkipsUnavailableActions() throws {
        let f = try SetupFixture(), model = try f.model()
        try (f.script + "echo unsupported\n").write(to: f.executable, atomically: true, encoding: .utf8)
        model.openSetup()
        model.move(.down); model.confirm()
        XCTAssertTrue(model.showingSaveSetup)
        XCTAssertEqual(model.protectionFocus, 1)
        model.move(.down)
        XCTAssertEqual(model.protectionFocus, 3)
        model.move(.up)
        XCTAssertEqual(model.protectionFocus, 1)
        model.setupSaveSource = f.source
        model.move(.down)
        XCTAssertEqual(model.protectionFocus, 2)
        model.back()
        XCTAssertFalse(model.showingSaveSetup)
        XCTAssertTrue(model.showingSetup)
    }
    @MainActor func testEmptyLibraryCannotEnterInvisibleSetup() throws {
        let f = try SetupFixture(), model = try f.model()
        model.games = []; model.selectedID = nil
        model.openSetup()
        XCTAssertFalse(model.showingSetup)
        model.openSettings()
        XCTAssertTrue(model.showingSettings)
    }

}
