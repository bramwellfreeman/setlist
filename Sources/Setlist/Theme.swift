import SwiftUI

/// Design language lifted from bramwellfreeman.com — editorial minimal:
/// ink/paper, light hairlines, grey pills, electric-blue accent, uppercase caps.
enum Theme {
    static let ink      = Color(hex: 0x111111)
    static let paper    = Color.white
    static let muted    = Color(hex: 0x8A8A8A)
    static let pill     = Color(hex: 0xEFEFEF)
    static let pillHover = Color(hex: 0xE4E4E4)
    static let line     = Color(hex: 0xE6E6E6)
    static let blue     = Color(hex: 0x2222EE)
    static let faint    = Color(hex: 0xFAFAFA)
    // Quiet, browser-like chrome
    static let tab         = Color(hex: 0xEBEBEB)   // selected tab / selected row
    static let hover       = Color(hex: 0xF4F4F4)
    static let faintIcon   = Color(hex: 0xB4B4B4)
    static let placeholder = Color(hex: 0xA6A6A6)
    static let cardBorder  = Color(hex: 0xE4E4E4)
}

extension View {
    /// White rounded card with a hairline border and a wide, very soft shadow.
    func floatingCard(radius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.paper)
                    .shadow(color: .black.opacity(0.07), radius: 36, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Logo mark

/// "S." monogram — Didot Bold capital with an electric-blue full stop,
/// matching the app icon (logo/setlist-icon.svg).
struct SetlistMark: View {
    var size: CGFloat = 22          // cap height-ish
    var color: Color = Theme.ink

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.06) {
            Text("S")
                .font(.custom("Didot-Bold", size: size * 1.4))
                .foregroundStyle(color)
            Circle()
                .fill(Theme.blue)
                .frame(width: size * 0.3, height: size * 0.3)
                .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
        }
    }
}

// MARK: - Uppercase label style

private struct CapsLabel: ViewModifier {
    var size: CGFloat
    var color: Color
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .semibold))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension View {
    func caps(_ size: CGFloat = 11, color: Color = Theme.muted) -> some View {
        modifier(CapsLabel(size: size, color: color))
    }
}

// MARK: - Pill button

struct PillButtonStyle: ButtonStyle {
    var active: Bool = false
    var accent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = active ? Theme.ink
            : (accent ? Theme.blue : (configuration.isPressed ? Theme.pillHover : Theme.pill))
        let fg: Color = (active || accent) ? .white : Theme.ink
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .tracking(0.6)
            .textCase(.uppercase)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// Small round transport button.
struct TransportButtonStyle: ButtonStyle {
    var filled: Bool = false
    var diameter: CGFloat = 38
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: filled ? 15 : 13, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .background(filled ? Theme.ink : (configuration.isPressed ? Theme.pillHover : Theme.pill))
            .foregroundStyle(filled ? Color.white : Theme.ink)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
