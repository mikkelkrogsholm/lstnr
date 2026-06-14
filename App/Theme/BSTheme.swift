import AppKit
import SwiftUI

/// Brokk & Sindre brand theme for Vara.
/// Palette and typography extracted from brokk-sindre.dk. Dark-first; every
/// color carries a light-mode counterpart so windows can follow the system
/// appearance. The HUD always uses the dark palette.
enum BSTheme {
    // MARK: Surfaces

    /// Window background. Dark: near-black `#0a0a0f`. Light: cool mist `#f5f7f9`.
    static let background = dynamicColor(dark: 0x0A0A0F, light: 0xF5F7F9)

    /// Card/panel surface. Dark: `#121218`. Light: white.
    static let surface = dynamicColor(dark: 0x121218, light: 0xFFFFFF)

    /// Hovered/raised surface. Dark: `#1a1a24`. Light: `#e8f0f4`.
    static let surfaceHover = dynamicColor(dark: 0x1A1A24, light: 0xE8F0F4)

    /// Deep petrol — the brand's signature dark tone, used for emphasis fills.
    static let petrol = Color(hex: 0x0A1E27)

    // MARK: Text

    static let textPrimary = dynamicColor(dark: 0xF0F0F5, light: 0x0A1E27)
    static let textMuted = dynamicColor(dark: 0x9696A6, light: 0x5F6E76)

    // MARK: Brand accents

    /// Nordic teal — idle/ready states and brand chrome.
    static let teal = Color(hex: 0x406E76)
    static let tealLight = Color(hex: 0x5A9AA5)
    static let cyan = Color(hex: 0x7EC8D4)

    /// Forge gold — recording and "smithing" (transcribing/cleanup) states.
    static let ember = Color(hex: 0xCA8A04)
    static let emberGlow = Color(hex: 0xEAB308)

    /// Subtle teal-tinted border for cards and controls.
    static let border = dynamicColor(dark: 0x406E76, light: 0x406E76, darkAlpha: 0.20, lightAlpha: 0.25)

    // MARK: Semantic states

    static let stateIdle = teal
    static let stateRecording = emberGlow
    static let stateForging = ember
    static let stateInserted = tealLight
    static let stateError = Color(hex: 0xE8A33D)

    // MARK: Metrics

    static let cornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 16

    // MARK: Typography

    /// Display font (Jost) for headings and the wordmark; falls back to the
    /// system font when the bundled font isn't registered (e.g. `swift run`).
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if jostIsAvailable {
            return .custom("Jost", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced font for timers, latency figures and log lines.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private static let jostIsAvailable: Bool =
        NSFontManager.shared.availableFontFamilies.contains("Jost")

    // MARK: Helpers

    private static func dynamicColor(
        dark: UInt32,
        light: UInt32,
        darkAlpha: CGFloat = 1,
        lightAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension Color {
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Shared components

/// Standard themed card container.
struct BSCard<Content: View>: View {
    var padding: CGFloat = BSTheme.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BSTheme.surface, in: RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
                    .strokeBorder(BSTheme.border)
            }
    }
}

/// Small status capsule with a colored dot.
struct StatusPill: View {
    let text: String
    let tint: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.25))
        }
    }
}

/// Renders a keyboard shortcut as physical key caps, e.g. ⌘ + ⌥.
struct KeyCapView: View {
    let keys: [String]
    var size: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(BSTheme.textMuted)
                }
                keyCap(key)
            }
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(BSTheme.textPrimary)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, label.count > 2 ? 10 : 0)
            .background(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(BSTheme.surfaceHover)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 2)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(BSTheme.border)
            }
    }
}

/// Pulsing forge-glow shadow for recording states.
struct EmberGlow: ViewModifier {
    var active: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .shadow(
                color: BSTheme.emberGlow.opacity(active ? (pulsing ? 0.55 : 0.25) : 0),
                radius: pulsing ? 14 : 8
            )
            .onChange(of: active, initial: true) { _, isActive in
                if isActive {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        pulsing = false
                    }
                }
            }
    }
}

extension View {
    func emberGlow(active: Bool) -> some View {
        modifier(EmberGlow(active: active))
    }
}

#Preview("Theme components") {
    VStack(alignment: .leading, spacing: 20) {
        Text("Vara")
            .font(BSTheme.display(32))
            .foregroundStyle(BSTheme.textPrimary)

        HStack {
            StatusPill(text: "Klar", tint: BSTheme.stateIdle)
            StatusPill(text: "Optager", tint: BSTheme.stateRecording)
            StatusPill(text: "Mangler adgang", tint: BSTheme.stateError, systemImage: "exclamationmark.triangle.fill")
        }

        KeyCapView(keys: ["⌘", "⌥"])

        BSCard {
            Text("Et kort med indhold")
                .foregroundStyle(BSTheme.textPrimary)
        }

        Circle()
            .fill(BSTheme.emberGlow)
            .frame(width: 24, height: 24)
            .emberGlow(active: true)
    }
    .padding(40)
    .background(BSTheme.background)
}
