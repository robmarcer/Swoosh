import AppKit
import SwiftUI
import Combine

/// Non-activating feedback remains visible above a fullscreen game without taking focus.
@MainActor final class HomeProgressPanel {
    private var observation: AnyCancellable?
    private let panel: NSPanel
    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HomeHoldFeedback(model: model))
        observation = model.$homeProgress.sink { [weak self] value in
            guard let self else { return }
            if value > 0 && value < 1 {
                if let screen = NSScreen.main {
                    self.panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 165, y: screen.visibleFrame.maxY - 120))
                }
                self.panel.orderFrontRegardless()
            } else { self.panel.orderOut(nil) }
        }
    }
}

private struct HomeHoldFeedback: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Text("Hold View + Menu for Swoosh").font(.system(size: 15, weight: .semibold))
            ProgressView(value: model.homeProgress).tint(.green)
        }.padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).preferredColorScheme(.dark)
    }
}
