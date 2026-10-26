import AppKit
import GameController
import SwooshCore

@MainActor final class ControllerInput {
    private weak var model: AppModel?
    private var timer: Timer?
    private var keyboard: Any?
    private var pressed = Set<String>()
    private var heldDirection: Direction?
    private var repeatAt = Date.distantFuture
    private var hold = HomeHold()
    private var armed = false
    private var wasActive = false
    private var activeController: ObjectIdentifier?

    init(model: AppModel) {
        self.model = model
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.modifierFlags.contains(.command), let self, let model = self.model else { return event }
            if model.choosingSaveLocation { return event }
            switch event.keyCode {
            case 123: model.move(.left)
            case 124: model.move(.right)
            case 125: model.move(.down)
            case 126: model.move(.up)
            case 36, 49: if !event.isARepeat { model.confirm() }
            case 53: model.back()
            case 1: if !event.isARepeat { model.openSettings() }
            case 2: if !event.isARepeat { model.openSetup() }
            case 15: if !event.isARepeat { model.refreshVersions(force: true) }
            default: return event
            }
            return nil
        }
    }

    private func poll() {
        guard let model else { return }
        let controllers = GCController.controllers()
        let controller = controllers.first { $0.extendedGamepad != nil }
        let identity = controller.map { ObjectIdentifier($0) }
        if identity != activeController {
            // A button held while connecting must be released before it can trigger an action.
            activeController = identity; pressed = ["a", "b", "y", "menu"]; heldDirection = nil
            hold = HomeHold(); armed = false; model.homeProgress = 0
        }
        let name = controller?.vendorName ?? (controller == nil ? nil : "Controller")
        if model.controllerName != name { model.controllerName = name }
        guard let pad = controller?.extendedGamepad else { model.homeProgress = 0; return }
        let now = Date()
        let chord = pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed ?? false)
        let triggered = hold.update(pressed: chord, eligible: model.running != nil, now: ProcessInfo.processInfo.systemUptime)
        if model.homeProgress != hold.progress { model.homeProgress = hold.progress }
        if triggered { armed = false; model.requestHome() }
        if chord { return }
        // Require neutral input after reconnecting or returning from a game.
        let active = NSApp.isActive
        if active && !wasActive { armed = false }
        wasActive = active
        guard active else { armed = false; heldDirection = nil; return }
        if !armed {
            let neutral = !pad.buttonA.isPressed && !pad.buttonB.isPressed && !pad.buttonY.isPressed && !pad.buttonX.isPressed && !pad.buttonMenu.isPressed && !(pad.buttonOptions?.isPressed ?? false)
                && abs(pad.dpad.xAxis.value) < 0.2 && abs(pad.dpad.yAxis.value) < 0.2
                && abs(pad.leftThumbstick.xAxis.value) < 0.2 && abs(pad.leftThumbstick.yAxis.value) < 0.2
            if neutral { armed = true; pressed.removeAll(); heldDirection = nil }
            return
        }
        let x = abs(pad.dpad.xAxis.value) > 0.5 ? pad.dpad.xAxis.value : pad.leftThumbstick.xAxis.value
        let y = abs(pad.dpad.yAxis.value) > 0.5 ? pad.dpad.yAxis.value : pad.leftThumbstick.yAxis.value
        let direction: Direction? = abs(x) > abs(y) && abs(x) > 0.65 ? (x > 0 ? .right : .left) : (abs(y) > 0.65 ? (y > 0 ? .up : .down) : nil)
        if let direction {
            if direction != heldDirection { model.move(direction); repeatAt = now.addingTimeInterval(0.4) }
            else if now >= repeatAt { model.move(direction); repeatAt = now.addingTimeInterval(0.15) }
        }
        heldDirection = direction
        edge("a", pad.buttonA.isPressed) { model.confirm() }
        edge("b", pad.buttonB.isPressed) { model.back() }
        edge("x", pad.buttonX.isPressed) { model.openSetup() }
        edge("y", pad.buttonY.isPressed) { if model.running == nil && !model.showingSettings { model.refreshVersions(force: true) } }
        edge("menu", pad.buttonMenu.isPressed) { model.openSettings() }
    }

    private func edge(_ key: String, _ down: Bool, action: () -> Void) {
        if down && !pressed.contains(key) { pressed.insert(key); action() }
        if !down { pressed.remove(key) }
    }
}
