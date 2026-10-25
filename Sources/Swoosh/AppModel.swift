@preconcurrency import AppKit
import SwiftUI
import ServiceManagement
import SwooshCore

@MainActor final class AppModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var selectedID: String?
    @Published var controllerName: String?
    @Published var issue: String?
    @Published var running: NSRunningApplication?
    @Published var runningName: String?
    @Published var launching = false
    @Published var showingSettings = false
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
    private var versionTask: Task<Void, Never>?
    private var nextVersionCheck = Date.distantPast

    init() {
        // Override is for development / testing; the installed app defaults to the agreed folder.
        folder = ProcessInfo.processInfo.environment["SWOOSH_LIBRARY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Switch", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { issue = "Could not create the game folder: \(error.localizedDescription)" }
        refresh()
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
        loadArtwork(for: scan.games)
        refreshVersions()
    }

    func versionStatus(for game: Game) -> VersionComparison {
        VersionComparison.compare(game.installedVersion, release: game.installedVersion.flatMap { releaseSnapshot?.releases[$0.titleID] })
    }

    func refreshVersions(force: Bool = false) {
        guard versionTask == nil, games.contains(where: { $0.installedVersion != nil }), force || Date() >= nextVersionCheck else { return }
        checkingVersions = true
        versionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.releaseStore.releases(force: force)
            self.releaseSnapshot = snapshot
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
        if showingQuit { quitFocused = direction == .right; return }
        if showingSettings {
            if direction == .down { settingsFocus = min(3, settingsFocus + 1) }
            if direction == .up { settingsFocus = max(0, settingsFocus - 1) }
            return
        }
        guard running == nil, !launching, !games.isEmpty else { return }
        let index = games.firstIndex { $0.id == selectedID } ?? 0
        selectedID = games[GridNavigation.next(index, direction: direction, count: games.count, columns: columns)].id
    }

    func confirm() {
        if issue != nil { issue = nil; return }
        if showingQuit { quitFocused ? quitGame() : resume(); return }
        if showingSettings {
            switch settingsFocus {
            case 0: setFullscreen(!fullscreen)
            case 1: toggleLogin()
            case 2: toggleArtwork()
            default: showingSettings = false
            }
            return
        }
        if running != nil { resume(); return }
        launchSelected()
    }

    func back() {
        if issue != nil { issue = nil }
        else if showingQuit { resume() }
        else if showingSettings { showingSettings = false }
        else if running != nil { resume() }
    }

    func openSettings() {
        guard running == nil, !launching else { return }
        showingSettings.toggle(); settingsFocus = 0
    }

    func launchSelected() {
        guard let game = selected, running == nil, !launching else { return }
        launching = true; runningName = game.name; issue = nil
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Scoped to this game process; no global environment changes.
        config.environment = ["DM_FULLSCREEN": "1"]
        NSWorkspace.shared.openApplication(at: game.url, configuration: config) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launching = false
                guard let app, error == nil else {
                    self.runningName = nil
                    self.issue = "Could not open \(game.name). \(error?.localizedDescription ?? "Try opening the game directly to check its installation.")"
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
                self.running = app
                self.didLaunch = true
                if app.isTerminated { self.finishSession() }
            }
        }
    }

    func requestHome() {
        guard running != nil, !launching, !showingQuit else { return }
        showingQuit = true; quitFocused = false
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func resume() {
        showingQuit = false
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
        running = nil; runningName = nil; showingQuit = false; launching = false
        if didLaunch { NSApp.activate(ignoringOtherApps: true) }
    }

    func setFullscreen(_ enabled: Bool) {
        fullscreen = enabled; UserDefaults.standard.set(enabled, forKey: "fullscreen")
        guard let window = NSApp.windows.first else { return }
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
