import AppKit
import UniformTypeIdentifiers
import SwooshCore

extension AppModel {
    var canConfigureGame: Bool {
        running == nil && !launching && !saving && !updatingLauncher && !choosingSaveLocation &&
        !games.contains { activeGamePaths.contains($0.url.path) }
    }

    var reviewedTitleID: String {
        (selected?.installedVersion?.titleID ?? setupTitleID).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var automaticSaveSetupAvailable: Bool {
        guard let game = selected, let assessment = NXnativeSetup.assess(app: game.url, titleID: reviewedTitleID) else { return false }
        return assessment.preservesSaveVariable || assessment.canRepair
    }
    var protectionActions: [Int] {
        (automaticSaveSetupAvailable ? [0, 1] : [1]) + (setupSaveSource == nil ? [] : [2]) + [3]
    }

    func protectionStatus(_ game: Game) -> String {
        guard game.canLaunch else { return "Incomplete · game setup" }
        guard let id = game.titleID else { return "Incomplete · title ID needed" }
        do {
            guard let config = try setupStore.configuration(game: game, libraryRoot: folder) else { return "Unmanaged saves" }
            if config.mode == .environment {
                guard NXnativeSetup.assess(app: game.url, titleID: id)?.preservesSaveVariable == true else { return "Incomplete · recheck save setup" }
            }
            guard FileManager.default.fileExists(atPath: saveLocation.appendingPathComponent(id + "/live").path) else { return "Incomplete · protect existing saves" }
            return config.mode == .copy ? "Protected saves · fixed-folder copy" : "Protected saves"
        } catch { return "Incomplete · recheck save setup" }
    }

    private func checkStorageSeparation(_ url: URL, app: URL? = nil) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != "/", path != FileManager.default.homeDirectoryForCurrentUser.path else { throw GameSetupError.unsafePath }
        for root in [saveLocation, SaveStore.localSessions, setupStore.root] {
            let other = root.resolvingSymlinksInPath().standardizedFileURL.path
            if path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/") { throw GameSetupError.unsafePath }
        }
        if let app {
            let installation = app.resolvingSymlinksInPath().path
            if installation == path || installation.hasPrefix(path + "/") { throw GameSetupError.unsafePath }
        }
    }

    func chooseGame() {
        guard !showingSetup, !showingSaveSetup, !showingSaves, !showingUpdate else { return }
        guard canConfigureGame else { issue = GameSetupError.active.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.title = "Add converted game"
        panel.message = "Choose a working macOS game app. Its original app and game-data folders will stay in place."
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = "Add game"
        choosingSaveLocation = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.choosingSaveLocation = false
                if response == .OK, let app = panel.url { self.importGame(app) }
            }
        }
    }

    func importGame(_ app: URL) {
        guard canConfigureGame else { issue = GameSetupError.active.localizedDescription; return }
        do {
            try checkStorageSeparation(app)
            try setupStore.register(app: app, titleID: nil, imported: true, existing: games, activeApps: activeGamePaths)
            refresh(); selectedID = app.resolvingSymlinksInPath().standardizedFileURL.path
            showingSettings = false; showingSetup = true; setupFocus = 0
            setupTitleID = selected?.titleID ?? ""
            setupMessage = "Added by reference. The original installation stays in place."
        } catch { issue = error.localizedDescription }
    }

    func openSaveSetup() {
        guard canConfigureGame, let game = selected else { issue = GameSetupError.active.localizedDescription; return }
        guard game.canLaunch else { issue = GameSetupError.invalidApp.localizedDescription; return }
        let id = reviewedTitleID
        guard InstalledGameVersion.validTitleID(id), game.installedVersion == nil || game.installedVersion?.titleID == id else { issue = GameSetupError.identity.localizedDescription; return }
        let assessment = NXnativeSetup.assess(app: game.url, titleID: id)
        setupUsesCopy = assessment == nil || !(assessment!.preservesSaveVariable || assessment!.canRepair)
        setupSaveSource = setupUsesCopy ? nil : assessment?.saveFolder
        protectionFocus = setupUsesCopy ? 1 : 0; showingSaveSetup = true
    }

    func protectionAction(_ index: Int) {
        guard !saving, !choosingSaveLocation else { return }
        switch index {
        case 0:
            guard let game = selected, let assessment = NXnativeSetup.assess(app: game.url, titleID: reviewedTitleID), assessment.preservesSaveVariable || assessment.canRepair else {
                issue = "Automatic save setup is unavailable for this launcher. Choose its existing fixed save folder instead."; return
            }
            setupUsesCopy = false; setupSaveSource = assessment.saveFolder
        case 1: chooseRuntimeSaveFolder()
        case 2:
            Task { @MainActor in
                do { try await configureProtection() }
                catch { self.issue = "Save setup stopped. " + error.localizedDescription }
            }
        default: showingSaveSetup = false
        }
    }

    func chooseRuntimeSaveFolder() {
        guard canConfigureGame else { issue = GameSetupError.active.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.title = "Existing game save folder"
        panel.message = "Choose the dedicated folder this game reads and writes. Swoosh will copy protected saves into it before launch and back out after exit. Choose only this game's save folder."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = "Use save folder"
        choosingSaveLocation = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.choosingSaveLocation = false
                if response == .OK, let url = panel.url { self.setupUsesCopy = true; self.setupSaveSource = url }
            }
        }
    }

    func configureProtection() async throws {
        guard canConfigureGame, let game = selected else { throw GameSetupError.active }
        guard game.canLaunch else { throw GameSetupError.invalidApp }
        let id = reviewedTitleID
        guard InstalledGameVersion.validTitleID(id), game.installedVersion == nil || game.installedVersion?.titleID == id else { throw GameSetupError.identity }
        guard let source = setupSaveSource, FileManager.default.fileExists(atPath: source.path) else { throw SaveError.invalidConfiguration }
        try checkStorageSeparation(source, app: game.url)
        // Read and validate records before touching a launcher or copying saves.
        _ = try setupStore.registrations()
        let assessment = setupUsesCopy ? nil : NXnativeSetup.assess(app: game.url, titleID: id)
        if !setupUsesCopy && assessment == nil { throw GameSetupError.unsupported }
        let config = SaveConfiguration(mode: setupUsesCopy ? .copy : .environment, path: source.path,
                                       environmentVariable: setupUsesCopy ? nil : "DM_SAVE")
        if let assessment, assessment.saveFolder.standardizedFileURL != source.standardizedFileURL { throw GameSetupError.changed }
        saving = true
        defer { saving = false }
        var repaired = false
        do {
            try await saveStore.validateSetupSource(titleID: id, app: game.url, config: config, activeApps: activeGamePaths)
            guard !activeGamePaths.contains(game.url.path) else { throw GameSetupError.active }
            if let assessment { repaired = try NXnativeSetup.repair(assessment, backupRoot: setupStore.root.appendingPathComponent("LauncherBackups")) != nil }
            _ = try await saveStore.prepare(titleID: id, app: game.url, config: config, activeApps: activeGamePaths)
            try await saveStore.recover(titleID: id, activeApps: activeGamePaths)
            guard !activeGamePaths.contains(game.url.path) else { throw GameSetupError.active }
            if config.mode == .environment, NXnativeSetup.assess(app: game.url, titleID: id)?.preservesSaveVariable != true { throw GameSetupError.changed }
            try setupStore.register(app: game.url, titleID: id, imported: false, activeApps: activeGamePaths)
            try setupStore.save(titleID: id, configuration: config, verification: setupUsesCopy ? "explicit-copy" : "supported-wrapper")
            refresh(); setupMessage = "Save protection verified. Originals retained; a backup was created."
            showingSaveSetup = false
        } catch {
            if repaired, let assessment, !activeGamePaths.contains(game.url.path) { try? NXnativeSetup.undoRepair(assessment) }
            throw error
        }
    }
}
