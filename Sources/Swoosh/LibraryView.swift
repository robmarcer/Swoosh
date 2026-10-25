import AppKit
import SwiftUI
import SwooshCore

private enum Palette {
    static let background = Color(red: 0.045, green: 0.075, blue: 0.085)
    static let surface = Color(red: 0.085, green: 0.12, blue: 0.13)
    static let ink = Color(red: 0.95, green: 0.95, blue: 0.89)
    static let muted = Color(red: 0.62, green: 0.70, blue: 0.70)
    static let accent = Color(red: 0.88, green: 0.98, blue: 0.54)
}

struct LibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 1180 ? 4 : (geometry.size.width >= 900 ? 3 : 2)
            ZStack {
                Palette.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 28) {
                    header
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("YOUR LIBRARY").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(3).foregroundStyle(Palette.accent)
                            Text("What’s next?").font(.system(size: 44, weight: .medium, design: .rounded)).tracking(-1.8)
                        }
                        Spacer()
                        Text("\(model.games.count) \(model.games.count == 1 ? "game" : "games")").font(.system(size: 16)).foregroundStyle(Palette.muted)
                    }
                    if model.games.isEmpty { emptyLibrary.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: columns), spacing: 24) {
                                    ForEach(model.games) { game in
                                        GameTile(game: game, selected: game.id == model.selected?.id, updateAvailable: model.versionStatus(for: game) == .updateAvailable, latest: model.latestRelease(for: game)) {
                                            if model.selectedID == game.id { model.launchSelected() }
                                            else { model.selectedID = game.id }
                                        }.id(game.id)
                                    }
                                }.padding(6)
                            }
                            .onChange(of: model.selectedID) { _, id in
                                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                            }
                        }
                    }
                    if let selected = model.selected {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("READY TO PLAY").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Palette.muted)
                                Text(selected.name).font(.system(size: 24, weight: .medium)).lineLimit(2)
                                versionDetail(selected)
                                HStack(spacing: 16) {
                                    if let artwork = model.selectedArtwork {
                                        Link("Artwork · \(artwork.sourceName)", destination: artwork.sourceURL).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    }
                                    if selected.installedVersion != nil {
                                        Link(model.releaseSnapshot?.isStale == true ? "Release data · cached" : "Release data · TitleDB", destination: GameReleaseStore.sourceURL).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    }
                                    if let source = model.latestRelease(for: selected)?.versionSourceURL {
                                        Link("Version label · NXnative", destination: source).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    }
                                }
                            }
                            Spacer(minLength: 20)
                            Button { model.confirm() } label: {
                                HStack(spacing: 12) { ButtonGlyph(label: "A"); Text("Play").fontWeight(.semibold) }
                                    .padding(.horizontal, 26).padding(.vertical, 15)
                                    .foregroundStyle(Palette.background).background(Palette.accent, in: Capsule())
                            }.buttonStyle(.plain).disabled(model.launching || model.running != nil)
                        }
                    }
                    footer
                }.padding(.horizontal, 42).padding(.top, 30).padding(.bottom, 26)
                if model.showingSettings { settings }
                if model.launching { overlay(title: "Opening \(model.runningName ?? "game")", subtitle: "Your game will open fullscreen.") { ProgressView().controlSize(.large) } }
                if model.running != nil && !model.showingQuit {
                    overlay(title: model.runningName ?? "Game running", subtitle: "Hold View + Menu for 1.5 seconds in a game to return here.") {
                        action("Return to game", selected: true) { model.resume() }
                        action("Quit game…", selected: false) { model.requestHome() }
                    }
                }
                if model.showingQuit {
                    overlay(title: "Back to your library?", subtitle: "Save in the game first. Quitting may lose unsaved progress.") {
                        HStack(spacing: 16) {
                            action("Keep playing", selected: !model.quitFocused) { model.resume() }
                            action("Quit game", selected: model.quitFocused) { model.quitGame() }
                        }
                    }
                }
                if let issue = model.issue {
                    overlay(title: "Something needs attention", subtitle: issue) {
                        action("A  Got it", selected: true) { model.issue = nil }
                    }
                }
            }
            .foregroundStyle(Palette.ink)
            .onAppear { model.columns = columns }
            .onChange(of: columns) { _, value in model.columns = value }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wind").font(.system(size: 28, weight: .medium)).foregroundStyle(Palette.accent)
            Text("swoosh").font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.8)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: model.controllerName == nil ? "gamecontroller" : "gamecontroller.fill")
                Text(model.controllerName == nil ? "Connect a controller" : "Controller connected")
            }.font(.system(size: 13)).foregroundStyle(Palette.muted)
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 20)).padding(12)
            }.buttonStyle(.plain).accessibilityLabel("Settings")
        }
    }

    private var footer: some View {
        HStack(spacing: 24) {
            hint("↔", "Browse")
            hint("A", "Play")
            hint("≡", "Settings")
            hint("Y", "Check updates")
            Spacer()
            Text(model.checkingVersions ? "Checking game releases…" : (model.fetchingArtwork ? "Finding artwork…" : "Library updates automatically")).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.padding(.top, 18).overlay(alignment: .top) { Rectangle().fill(Palette.muted.opacity(0.18)).frame(height: 1) }
    }

    @ViewBuilder private func versionDetail(_ game: Game) -> some View {
        if let installed = game.installedVersion {
            HStack(spacing: 12) {
                Text("Installed \(installed.label)").foregroundStyle(Palette.muted)
                if let latest = model.latestRelease(for: game) {
                    Text("→  Latest \(latest.label)").foregroundStyle(Palette.ink)
                }
                switch model.versionStatus(for: game) {
                case .updateAvailable:
                    Label("Update available", systemImage: "arrow.down.circle.fill").foregroundStyle(Color(red: 1, green: 0.78, blue: 0.35))
                case .latestKnown:
                    Text("Latest known").foregroundStyle(Palette.muted)
                case .newerThanCatalogue:
                    Text("Newer than catalogue").foregroundStyle(Palette.muted)
                case .unknown:
                    Text(model.checkingVersions ? "Checking…" : "Latest release unknown").foregroundStyle(Palette.muted)
                }
            }.font(.system(size: 14))
        } else {
            Text("Game version unavailable").font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44, weight: .light)).foregroundStyle(Palette.accent)
            Text("Make room for your next adventure.").font(.system(size: 26, weight: .medium))
            Text("Add a converted game and it will appear here.").foregroundStyle(Palette.muted)
            Text(model.folder.path).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
        }.multilineTextAlignment(.center).padding(28)
    }

    private var settings: some View {
        overlay(title: "Make yourself at home.", subtitle: "Library settings") {
            VStack(spacing: 12) {
                action("Fullscreen     \(model.fullscreen ? "On" : "Off")", selected: model.settingsFocus == 0) { model.setFullscreen(!model.fullscreen) }
                action("Open at login     \(model.loginEnabled ? "On" : "Off")", selected: model.settingsFocus == 1) { model.toggleLogin() }
                action("Download artwork     \(model.artworkEnabled ? "On" : "Off")", selected: model.settingsFocus == 2) { model.toggleArtwork() }
                action("Done", selected: model.settingsFocus == 3) { model.showingSettings = false }
                Text(model.folder.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 12).textSelection(.enabled)
                Text("↑ ↓ Select     A Confirm     B Back").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 8) { ButtonGlyph(label: key); Text(text).font(.system(size: 13)).foregroundStyle(Palette.muted) }
    }

    private func action(_ title: String, selected: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(.system(size: 17, weight: .medium)).padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(selected ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(selected ? Palette.background : Palette.ink)
        }.buttonStyle(.plain)
    }

    private func overlay<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Palette.background.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 24) {
                Text(title).font(.system(size: 32, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                Text(subtitle).font(.system(size: 16)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                content()
            }.padding(44).frame(maxWidth: 620).background(Palette.background)
        }
    }
}

private struct ButtonGlyph: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 12, weight: .bold)).frame(width: 25, height: 25)
            .overlay(Circle().strokeBorder(.foreground.opacity(0.5), lineWidth: 1))
    }
}

private struct GameTile: View {
    let game: Game
    let selected: Bool
    let updateAvailable: Bool
    let latest: GameRelease?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(red: 0.17, green: 0.30, blue: 0.31), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let url = game.coverURL, let image = NSImage(contentsOf: url) {
                        GeometryReader { geometry in
                            Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent)
                            Spacer()
                            Text(game.name).font(.system(size: 29, weight: .medium, design: .rounded)).tracking(-0.7).multilineTextAlignment(.leading).lineLimit(4)
                        }.padding(24)
                    }
                }.aspectRatio(0.85, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topTrailing) {
                        if updateAvailable {
                            Label("Update available", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9)
                                .foregroundStyle(Palette.background)
                                .background(Color(red: 1, green: 0.78, blue: 0.35), in: Capsule()).padding(12)
                        }
                    }
                Text(game.name).font(.system(size: 15, weight: selected ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                if let installed = game.installedVersion {
                    HStack(spacing: 8) {
                        Text("Installed \(installed.label)")
                        Text("→")
                        Text(latest.map { "Latest \($0.label)" } ?? "Latest unknown")
                    }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            .padding(8)
            .background(selected ? Palette.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(selected ? Palette.accent : Color.clear, lineWidth: 3))
            .foregroundStyle(Palette.ink)
        }.buttonStyle(.plain).accessibilityLabel("\(game.name)\(updateAvailable ? ", update available" : "")\(selected ? ", selected. Activate to play" : "")")
    }
}
