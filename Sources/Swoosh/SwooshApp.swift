import AppKit
import SwiftUI
import SwooshCore

@main enum SwooshMain {
    @MainActor static func main() {
        let lock = InstanceLock()
        switch lock.status {
        case .acquired:
            withExtendedLifetime(lock) { SwooshApp.main() }
        case .alreadyRunning:
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("dev.swoosh.launcher.activate"), object: nil, userInfo: nil, deliverImmediately: true)
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "dev.swoosh.launcher" }?.activate(options: [])
        case .unavailable(let code):
            let alert = NSAlert()
            alert.messageText = "Swoosh could not start"
            alert.informativeText = "The single-instance lock is unavailable (error \(code)). Another login session or a file permission may need attention."
            alert.runModal()
        }
    }
}

struct SwooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            LibraryView(model: delegate.model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 620)
                .onAppear { delegate.prepareWindow() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Library settings") { delegate.model.openSettings() }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var input: ControllerInput?
    private var homeFeedback: HomeProgressPanel?
    private var prepared = false
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        input = ControllerInput(model: model)
        homeFeedback = HomeProgressPanel(model: model)
        NSApp.activate(ignoringOtherApps: true)
        activationObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.swoosh.launcher.activate"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func prepareWindow() {
        guard !prepared else { return }; prepared = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
            window.title = "Swoosh"
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            if model.fullscreen && ProcessInfo.processInfo.environment["SWOOSH_WINDOWED"] != "1" {
                window.toggleFullScreen(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.running != nil { model.requestHome(); return .terminateCancel }
        return .terminateNow
    }
}
