import AppKit
import Observation

/// Manual driving: turns the on-screen stick and the arrow keys / WASD into drive commands.
@MainActor
@Observable
final class DriveController {
    enum Speed: String, CaseIterable, Identifiable {
        case slow = "Slow", normal = "Normal", fast = "Fast"
        var id: String { rawValue }
        var maxVelocity: Double { switch self { case .slow: 150; case .normal: 300; case .fast: 600 } }
    }

    enum Key { case forward, back, left, right }

    private(set) var isActive = false
    /// -1...1 on both axes, y up is forward.
    var stick: CGSize = .zero
    var speed: Speed = .normal
    var invertTurning = false
    private(set) var keys: Set<Key> = []

    private static let maxRotation = 128.0
    private var loop: Task<Void, Never>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Stick and keyboard combined.
    var input: CGSize {
        var x = stick.width, y = stick.height
        if keys.contains(.right) { x += 1 }
        if keys.contains(.left) { x -= 1 }
        if keys.contains(.forward) { y += 1 }
        if keys.contains(.back) { y -= 1 }
        return CGSize(width: min(1, max(-1, x)), height: min(1, max(-1, y)))
    }

    func start(robot: RobotController) {
        guard !isActive else { return }
        isActive = true
        robot.setDriving(true)
        installKeyMonitor()
        loop = Task { [weak self] in
            var wasMoving = false
            while !Task.isCancelled {
                guard let self else { return }
                let v = self.input
                if abs(v.width) > 0.05 || abs(v.height) > 0.05 {
                    // Keep sending for as long as the stick is held, one command at a time.
                    let turn = (self.invertTurning ? 1.0 : -1.0) * v.width  // stick right = turn right
                    await robot.drive(rotation: Int((turn * Self.maxRotation).rounded()),
                                      velocity: Int((v.height * self.speed.maxVelocity).rounded()))
                    wasMoving = true
                    try? await Task.sleep(for: .milliseconds(60))
                } else {
                    if wasMoving {
                        await robot.drive(rotation: 0, velocity: 0)
                        wasMoving = false
                    }
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        }
    }

    func stop(robot: RobotController) {
        guard isActive else { return }
        isActive = false
        loop?.cancel()
        loop = nil
        stick = .zero
        keys = []
        removeKeyMonitor()
        robot.setDriving(false)
        Task { await robot.endRemoteSession() }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let key = Self.key(for: event),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(NSApp.keyWindow?.firstResponder is NSText)  // typing in a text field
                else { return event }
                if event.type == .keyDown { self.keys.insert(key) } else { self.keys.remove(key) }
                return nil  // handled; no system beep
            }
        }
        // A key released while the app is in the background would otherwise stay "held".
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keys = [] }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
    }

    private static func key(for event: NSEvent) -> Key? {
        switch event.keyCode {
        case 126: return .forward
        case 125: return .back
        case 123: return .left
        case 124: return .right
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": return .forward
        case "s": return .back
        case "a": return .left
        case "d": return .right
        default: return nil
        }
    }
}
