import SwiftUI

/// Light, Dark, or follow the Mac (the default, as the HIG recommends).
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: Self { self }
    var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    /// nil = no override, so the app follows System Settings live.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension RobotController {
    /// The color of the status light: gray offline, orange on a problem, blue while working, green when docked.
    var statusTint: Color {
        guard isConnected, let status = int(Spec.status) else { return .gray }
        if status == 4 || connectionError != nil { return .orange }
        if isBusy { return .blue }
        if [6, 13].contains(status) { return .green }
        return .mint
    }
}

// MARK: - LED effects

/// Light bleeding from a lit element. Kept faint in Light Mode and a little stronger in Dark Mode,
/// where a glow reads as light rather than as a smudge.
private struct LEDGlow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let color: Color
    let radius: CGFloat
    let isOn: Bool

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .shadow(color: color.opacity(isOn ? (dark ? 0.65 : 0.3) : 0), radius: radius * 0.5)
            .shadow(color: color.opacity(isOn && dark ? 0.3 : 0), radius: radius * 1.6)
    }
}

extension View {
    func ledGlow(_ color: Color, radius: CGFloat = 6, isOn: Bool = true) -> some View {
        modifier(LEDGlow(color: color, radius: radius, isOn: isOn))
    }
}

/// A small indicator light. It glows steadily and breathes only while something is happening,
/// so a resting robot leaves the window calm.
struct StatusLED: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    var isActive = false
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color.gradient)
            .overlay {
                // A tiny highlight so it reads as a lens, not a flat dot.
                Circle()
                    .fill(.white.opacity(0.55))
                    .frame(width: size * 0.32, height: size * 0.32)
                    .offset(x: -size * 0.16, y: -size * 0.16)
                    .blur(radius: size * 0.06)
            }
            .frame(width: size, height: size)
            .phaseAnimator(isActive && !reduceMotion ? [1.0, 0.4] : [1.0]) { led, glow in
                led.ledGlow(color, radius: size * (0.6 + glow), isOn: true)
                    .opacity(0.75 + glow * 0.25)
            } animation: { _ in .easeInOut(duration: 1.3) }
            .accessibilityHidden(true)
    }
}

/// The window's backdrop: a quiet wash of color, deeper at night, so glass has something to refract.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color = .blue

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            (dark ? Color(red: 0.06, green: 0.07, blue: 0.09) : Color(red: 0.95, green: 0.96, blue: 0.98))
            RadialGradient(colors: [tint.opacity(dark ? 0.16 : 0.08), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.indigo.opacity(dark ? 0.12 : 0.05), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .animation(.smooth(duration: 1.2), value: tint)
        .ignoresSafeArea()
    }
}
