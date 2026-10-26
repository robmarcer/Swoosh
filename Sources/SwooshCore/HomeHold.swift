import Foundation

/// One activation per hold; release or disconnect resets the gesture.
public struct HomeHold {
    public private(set) var progress: Double = 0
    private var started: TimeInterval?
    private var triggered = false
    public init() {}
    public mutating func update(pressed: Bool, eligible: Bool, now: TimeInterval) -> Bool {
        guard pressed && eligible else {
            progress = 0; started = nil; triggered = false
            return false
        }
        if started == nil { started = now }
        progress = min(1, max(0, (now - started!) / 1.5))
        guard progress >= 1, !triggered else { return false }
        triggered = true
        return true
    }
}
