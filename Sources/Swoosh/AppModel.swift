@preconcurrency import AppKit
import SwiftUI
import ServiceManagement
import SwooshCore

@MainActor final class AppModel: ObservableObject {
    @Published var showingSaves = false
    @Published var saveSummary: SaveSummary?
    @Published var saveFocus = 0
    @Published var restoreCandidate: SaveBackup?
    @Published var restoreFocused = false
    @Published var saving = false
    @Published var saveMessage = ""
    private let saveStore = SaveStore()
    private var managedTitleID: String?
    @Published var games: [Game] = []
    @Published var selectedID: String?
    @Published var controllerName: String?
    @Published var issue: String?
    @Published var running: NSRunningApplication?
    @Published var runningName: String?
    @Published var launching = false
    @Published var showingSettings = false
    @Published var showingSetup = false
    @Published var setupFocus = 0
    @Published var showingHome = false
    @Published var homeFocus = 0
    @Published var homeProgress: Double = 0
    @Published var runningID: String?
    @Published var showingQuit = false
    @Published var quitFocused = false
    @Published var settingsFocus = 0
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var fullscreen = UserDefaults.standard.object(forKey: "fullscreen") as? Bool ?? true
    @Published var artworkEnabled = UserDefaults.standard.object(forKey: "artworkEnabled") as? Bool ?? true
    @Published var artworks: [String: Artwork] = [:]
    @Published var fetchingArtwork = false
    @Published var releaseSnapshot: ReleaseSnapshot?
    @Published var checkingVersions = false
    var columns = 4
    let folder: URL
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var didLaunch = false
    private let artworkStore = ArtworkStore()
    private var artworkTask: Task<Void, Never>?
    private var artworkRetryAt: [String: Date] = [:]
    private let releaseStore = GameReleaseStore()
    private let releaseLabelStore = ReleaseLabelStore()
    private var versionTask: Task<Void, Never>?
    private var nextVersionCheck = Date.distantPast

    private let backgroundServices: Bool

    init(library: URL? = nil, backgroundServices: Bool = true) {
        self.backgroundServices = backgroundServices
        // Override is for development / testing; the installed app defaults to the agreed folder.
        folder = library ?? ProcessInfo.processInfo.environment["SWOOSH_LIBRARY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Switch", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { issue = "Could not create the game folder: \(error.localizedDescription)" }
        refresh()
        guard backgroundServices else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processIdentifier = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, processIdentifier == self.running?.processIdentifier else { return }
                self.finishSession()
            }
        }
    }

    var selected: Game? { games.first { $0.id == selectedID } ?? games.first }
    func refresh() {
        let scan = Library.scan(folder)
        let decorated = scan.games.map { game in
            if game.coverURL == nil, let artwork = artworks[game.name] { return game.withCover(artwork.imageURL) }
            return game
        }
        if games != decorated { games = decorated }
        if !games.contains(where: { $0.id == selectedID }) { selectedID = games.first?.id }
        if let problem = scan.issue { issue = problem }
        if running?.isTerminated == true { finishSession() }
        if backgroundServices {
            loadArtwork(for: scan.games)
            refreshVersions()
        }
    }

    func versionStatus(for game: Game) -> VersionComparison {
        VersionComparison.compare(game.installedVersion, release: latestRelease(for: game))
    }

    func latestRelease(for game: Game) -> GameRelease? {
        game.installedVersion.flatMap { releaseSnapshot?.releases[$0.titleID] }
    }

    func refreshVersions(force: Bool = false) {
        guard versionTask == nil, games.contains(where: { $0.installedVersion != nil }), force || Date() >= nextVersionCheck else { return }
        checkingVersions = true
        versionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshot = await self.releaseStore.releases(force: force)
            self.releaseSnapshot = snapshot
            let ids = Set(self.games.compactMap { $0.installedVersion?.titleID }).sorted()
            for id in ids {
                guard let release = snapshot?.releases[id] else { continue }
                if let label = await self.releaseLabelStore.label(titleID: id, contentVersion: release.contentVersion) {
                    var named = release
                    named.displayVersion = label.displayVersion
                    named.versionSourceURL = label.sourceURL
                    snapshot?.releases[id] = named
                    self.releaseSnapshot = snapshot
                }
            }
            self.nextVersionCheck = Date().addingTimeInterval(snapshot == nil || snapshot?.isStale == true ? 15 * 60 : 86400)
            self.checkingVersions = false
            self.versionTask = nil
        }
    }

    var selectedArtwork: Artwork? {
        guard let selected, let artwork = artworks[selected.name], selected.coverURL == artwork.imageURL else { return nil }
        return artwork
    }

    private func loadArtwork(for library: [Game]) {
        guard artworkTask == nil else { return }
        let pending = library.filter { $0.coverURL == nil && artworks[$0.name] == nil && (artworkRetryAt[$0.name] ?? .distantPast) <= Date() }
        guard !pending.isEmpty else { return }
        fetchingArtwork = true
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for game in pending {
                if Task.isCancelled { break }
                self.artworkRetryAt[game.name] = Date().addingTimeInterval(15 * 60)
                if let artwork = await self.artworkStore.artwork(for: game.name, allowNetwork: self.artworkEnabled), !Task.isCancelled {
                    self.artworks[game.name] = artwork
                    self.refresh()
                }
            }
            self.fetchingArtwork = false
            self.artworkTask = nil
        }
    }

    func toggleArtwork() {
        artworkEnabled.toggle()
        UserDefaults.standard.set(artworkEnabled, forKey: "artworkEnabled")
        if artworkEnabled { artworkRetryAt.removeAll() }
        else { artworkTask?.cancel() }
        refresh()
    }

    func move(_ direction: Direction) {
        if saving { return }
        if restoreCandidate != nil { restoreFocused = direction == .right; return }
        if showingSaves {
            if direction == .down { saveFocus = min((saveSummary?.backups.count ?? 0) + 1, saveFocus + 1) }
            if direction == .up { saveFocus = max(0, saveFocus - 1) }
            return
        }
        if showingSetup {
            if direction == .down { setupFocus = min(2, setupFocus + 1) }
            if direction == .up { setupFocus = max(0, setupFocus - 1) }
            return
        }
        if showingQuit { quitFocused = direction == .right; return }
        if showingHome {
            if direction == .down { homeFocus = min(2, homeFocus + 1) }
            if direction == .up { homeFocus = max(0, homeFocus - 1) }
            return
        }
        if showingSettings {
            if direction == .down { settingsFocus = min(3, settingsFocus + 1) }
            if direction == .up { settingsFocus = max(0, settingsFocus - 1) }
            return
        }
        guard !launching, !games.isEmpty else { return }
        let index = games.firstIndex { $0.id == selectedID } ?? 0
        selectedID = games[GridNavigation.next(index, direction: direction, count: games.count, columns: columns)].id
    }

    func confirm() {
        guard !saving else { return }
        if issue != nil { issue = nil; return }
        if let candidate = restoreCandidate {
            if restoreFocused { restoreBackup(candidate) } else { restoreCandidate = nil }
            return
        }
        if showingSaves {
            if saveSummary == nil { showingSaves = false; return }
            if saveFocus == 0 { cycleRetention() }
            else if saveFocus == 1 { showingSaves = false }
            else if let backups = saveSummary?.backups, backups.indices.contains(saveFocus - 2) {
                restoreCandidate = backups[saveFocus - 2]; restoreFocused = false
            }
            return
        }
        if showingSetup {
            if setupFocus == 0 { refresh() } else if setupFocus == 1 { openSaves() } else { showingSetup = false }
            return
        }
        if showingQuit { quitFocused ? quitGame() : resume(); return }
        if showingHome {
            switch homeFocus {
            case 0: resume()
            case 1: showingHome = false
            default: showingQuit = true; quitFocused = false
            }
            return
        }
        if showingSettings {
            switch settingsFocus {
            case 0: setFullscreen(!fullscreen)
            case 1: toggleLogin()
            case 2: toggleArtwork()
            default: showingSettings = false
            }
            return
        }
        if running != nil {
            if let selected, selected.id == runningID { resume() }
            else { issue = "Quit the running game before opening another one." }
            return
        }
        launchSelected()
    }

    func back() {
        guard !saving else { return }
        if issue != nil { issue = nil }
        else if restoreCandidate != nil { restoreCandidate = nil }
        else if showingSaves { showingSaves = false }
        else if showingSetup { showingSetup = false }
        else if showingQuit { showingQuit = false }
        else if showingHome { resume() }
        else if showingSettings { showingSettings = false }
        else if running != nil { resume() }
    }

    func openSetup() {
        guard !launching, !saving, !showingSaves, !showingHome, !showingQuit, !showingSettings else { return }
        showingSetup.toggle(); setupFocus = 0
    }

    func openSettings() {
        guard running == nil, !launching, !saving else { return }
        showingSettings.toggle(); settingsFocus = 0
    }

    private var activeGamePaths: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
    }

    func launchSelected() {
        guard let game = selected, running == nil, !launching, !saving else { return }
        guard game.canLaunch else { showingSetup = true; setupFocus = 0; return }
        launching = true; runningName = game.name; issue = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var environment = ["DM_FULLSCREEN": "1"]
                if let config = try SaveConfiguration.read(game: game, libraryRoot: self.folder) {
                    guard let id = game.installedVersion?.titleID else { throw SaveError.missingIdentity }
                    let values = try await self.saveStore.prepare(titleID: id, app: game.url, config: config, activeApps: self.activeGamePaths)
                    environment.merge(values) { _, value in value }
                    self.managedTitleID = id
                }
                self.openGame(game, environment: environment)
            } catch {
                self.launching = false; self.runningName = nil
                self.issue = "Save preparation stopped the launch. " + error.localizedDescription
            }
        }
    }

    private func openGame(_ game: Game, environment: [String: String]) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true; config.environment = environment
        NSWorkspace.shared.openApplication(at: game.url, configuration: config) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launching = false
                guard let app, error == nil else {
                    self.finishSession()
                    self.issue = "Could not open \(game.name). \(error?.localizedDescription ?? "Open Setup to recheck its installation, or test it directly.")"
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
                self.running = app; self.runningID = game.id; self.didLaunch = true
                if app.isTerminated { self.finishSession() }
            }
        }
    }

    func openSaves() {
        guard running == nil, !launching, !saving else { issue = "Exit the running game before managing saves."; return }
        showingSaves = true; saveFocus = 0; saveSummary = nil
        guard let game = selected, let id = game.installedVersion?.titleID else {
            saveMessage = "Add verified title metadata before managing saves."; return
        }
        saving = true
        Task { @MainActor in
            defer { self.saving = false }
            do {
                guard try SaveConfiguration.read(game: game, libraryRoot: self.folder) != nil else {
                    self.saveMessage = "Save management is not configured. Add a saves entry to this game’s SwooshGame.json using a verified save path. See the README for the runtime contract."
                    return
                }
                try await self.saveStore.recover(titleID: id, activeApps: self.activeGamePaths)
                self.saveSummary = try await self.saveStore.summary(titleID: id)
                self.saveMessage = "Saves stay outside the game installation. Backups are made before each managed launch."
            } catch { self.saveMessage = error.localizedDescription }
        }
    }

    func cycleRetention() {
        guard !saving, let id = selected?.installedVersion?.titleID, let summary = saveSummary else { return }
        let count = summary.retention == 5 ? 10 : (summary.retention == 10 ? 20 : 5)
        saving = true
        Task { @MainActor in
            defer { self.saving = false }
            do {
                try await self.saveStore.setRetention(titleID: id, count: count)
                self.saveSummary = try await self.saveStore.summary(titleID: id)
            } catch { self.issue = error.localizedDescription }
        }
    }

    func restoreBackup(_ item: SaveBackup) {
        guard running == nil, !launching, !saving, let id = selected?.installedVersion?.titleID else { return }
        guard let game = selected, !activeGamePaths.contains(game.url.resolvingSymlinksInPath().path) else { issue = SaveError.activeSession.localizedDescription; return }
        saving = true; restoreCandidate = nil
        Task { @MainActor in
            defer { self.saving = false }
            do {
                try await self.saveStore.restore(titleID: id, backupID: item.id, activeApps: self.activeGamePaths)
                self.saveSummary = try await self.saveStore.summary(titleID: id)
                self.saveMessage = "Backup restored. The previous saves were backed up first."
            } catch { self.issue = error.localizedDescription }
        }
    }

    func requestHome() {
        guard running != nil, !launching else { return }
        homeProgress = 0; showingHome = true; showingQuit = false; homeFocus = 0; quitFocused = false
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }

    func resume() {
        showingQuit = false; showingHome = false
        running?.activate(options: [])
    }

    func quitGame() {
        guard let app = running else { return }
        if !app.terminate() {
            showingQuit = false
            issue = "The game did not accept the quit request. Return to the game and exit from its menu."
        }
        // Never force-kill a game. Wait for macOS to report its termination.
    }

    func finishSession() {
        running = nil; runningName = nil; runningID = nil; showingHome = false; homeProgress = 0; showingQuit = false; launching = false
        if didLaunch { NSApp.activate(ignoringOtherApps: true) }
        if let id = managedTitleID {
            managedTitleID = nil; saving = true
            Task { @MainActor in
                defer { self.saving = false }
                do { try await self.saveStore.recover(titleID: id, activeApps: self.activeGamePaths) }
                catch { self.issue = "Save recovery needs attention. " + error.localizedDescription }
            }
        }
    }

    func setFullscreen(_ enabled: Bool) {
        fullscreen = enabled; UserDefaults.standard.set(enabled, forKey: "fullscreen")
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        if window.styleMask.contains(.fullScreen) != enabled { window.toggleFullScreen(nil) }
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                issue = "Allow Swoosh in System Settings → General → Login Items to finish enabling startup."
            }
        } catch { issue = "Could not update startup: \(error.localizedDescription)" }
    }
}
