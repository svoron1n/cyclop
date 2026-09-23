import SwiftUI

enum Theme {
    static let openAnimation = Animation.spring(response: 0.27, dampingFraction: 0.82)
    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    static let paneOut = Animation.easeIn(duration: 0.12)
    static let artworkAnimation = Animation.easeOut(duration: 0.28)

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    // Colours are looked up in the palette the view is drawn with, not fixed
    // here: see `Palette` and `ThemeColor`.
    static let background = ThemeColor(.background)
    static let header = ThemeColor(.header)
    static let headerText = ThemeColor(.headerText)
    static let headerTextStrong = ThemeColor(.headerTextStrong)
    static let text = ThemeColor(.text)
    static let secondary = ThemeColor(.secondary)
    static let tertiary = ThemeColor(.tertiary)
    static let surface = ThemeColor(.surface)
    static let surfaceHover = ThemeColor(.surfaceHover)
    static let hairline = ThemeColor(.hairline)
    static let icon = ThemeColor(.icon)
    static let iconInactive = ThemeColor(.iconInactive)
    static let accent = ThemeColor(.accent)
    static let success = ThemeColor(.success)
    static let warning = ThemeColor(.warning)
    /// Nothing, but of the same type as the rest — for the other branch of a
    /// `hovered ? Theme.surface : Theme.clear`.
    static let clear = ThemeColor(.background, alpha: 0)
}

/// One colour of the panel, named by its role rather than by its value.
///
/// A `ShapeStyle` rather than a `Color`: it is resolved against the palette in
/// the environment at the moment it is drawn, so switching the theme in
/// Settings repaints every view that uses it — including the ones whose own
/// inputs did not change and whose bodies SwiftUI would otherwise not rerun.
struct ThemeColor: ShapeStyle {
    enum Role: Sendable {
        case background, header, headerText, headerTextStrong
        case text, secondary, tertiary
        case surface, surfaceHover, hairline
        case icon, iconInactive
        case accent, success, warning
    }

    let role: Role
    var alpha: Double = 1

    init(_ role: Role, alpha: Double = 1) {
        self.role = role
        self.alpha = alpha
    }

    /// Same type back, unlike `ShapeStyle.opacity(_:)`, so both branches of
    /// `selected ? Theme.text.opacity(0.8) : Theme.tertiary` still agree.
    func opacity(_ value: Double) -> ThemeColor {
        ThemeColor(role, alpha: alpha * value)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.palette[role].opacity(alpha)
    }
}

extension EnvironmentValues {
    /// Set once at the root of the panel from `ConfigStore.theme`.
    @Entry var palette: Palette = .standard
}

/// Every colour the panel is drawn with.
struct Palette: Equatable {
    /// Decides the appearance of the AppKit controls under SwiftUI's — caret,
    /// placeholder, selection — which do not read this palette.
    var isDark: Bool
    var background: Color
    /// The strip at the top, the height of the menu bar. On a notched display
    /// the camera sits in the middle of it, which is why the light theme keeps
    /// it dark: a light strip there shows the notch as a black block.
    var header: Color
    var headerText: Color
    /// What in the header has to be seen — a meeting that is already on.
    var headerTextStrong: Color
    var text: Color
    var secondary: Color
    var tertiary: Color
    var surface: Color
    var surfaceHover: Color
    var hairline: Color
    /// The chosen tab on the rail; `iconInactive` is the rest.
    var icon: Color
    var iconInactive: Color
    var accent: Color
    var success: Color
    var warning: Color

    subscript(role: ThemeColor.Role) -> Color {
        switch role {
        case .background: background
        case .header: header
        case .headerText: headerText
        case .headerTextStrong: headerTextStrong
        case .text: text
        case .secondary: secondary
        case .tertiary: tertiary
        case .surface: surface
        case .surfaceHover: surfaceHover
        case .hairline: hairline
        case .icon: icon
        case .iconInactive: iconInactive
        case .accent: accent
        case .success: success
        case .warning: warning
        }
    }
}

// MARK: - Presets

extension Palette {
    /// White on black — what the panel has always been, and still the default.
    static let standard = Palette(
        isDark: true,
        background: .black,
        header: .black,
        headerText: .white.opacity(0.32),
        headerTextStrong: .white.opacity(0.8),
        text: .white,
        secondary: .white.opacity(0.55),
        tertiary: .white.opacity(0.32),
        surface: .white.opacity(0.08),
        surfaceHover: .white.opacity(0.14),
        hairline: .white.opacity(0.10),
        icon: .white,
        iconInactive: .white.opacity(0.32),
        accent: .accentColor,
        success: .green,
        warning: .yellow.opacity(0.85)
    )

    // The two below are the palette from the Vento de Forró logo
    // (color.romanuke.com/tsvetovaya-palitra-3653), with the same dark and
    // light values the Balance app uses for it:
    // ink #2A1A41, wine #823066, coral #DF6B6A, peach #F5C286, sky #ABD1E8.

    static let forroDark = Palette(
        isDark: true,
        background: Color(hex: "#2A1A41")!,
        header: Color(hex: "#241934")!,
        headerText: Color(hex: "#9384A0")!,
        headerTextStrong: Color(hex: "#F5ECF1")!,
        text: Color(hex: "#F5ECF1")!,
        secondary: Color(hex: "#B7A6C4")!,
        tertiary: Color(hex: "#9384A0")!,
        surface: Color(hex: "#F5ECF1")!.opacity(0.07),
        surfaceHover: Color(hex: "#F5ECF1")!.opacity(0.13),
        hairline: Color(hex: "#F5C286")!.opacity(0.16),
        icon: Color(hex: "#F5C286")!,
        iconInactive: Color(hex: "#9384A0")!,
        accent: Color(hex: "#DF6B6A")!,
        success: Color(hex: "#ABD1E8")!,
        warning: Color(hex: "#F5C286")!
    )

    static let forroLight = Palette(
        isDark: false,
        background: Color(hex: "#FBF4F2")!,
        header: Color(hex: "#2A1A41")!,
        headerText: Color(hex: "#B7A6C4")!,
        headerTextStrong: Color(hex: "#F5ECF1")!,
        text: Color(hex: "#2A1A41")!,
        secondary: Color(hex: "#8B7690")!,
        tertiary: Color(hex: "#AC91A6")!,
        surface: .white,
        surfaceHover: Color(hex: "#823066")!.opacity(0.10),
        hairline: Color(hex: "#823066")!.opacity(0.14),
        icon: Color(hex: "#823066")!,
        iconInactive: Color(hex: "#AC91A6")!,
        accent: Color(hex: "#823066")!,
        success: Color(hex: "#2F6F92")!,
        warning: Color(hex: "#9A6A1F")!
    )

    /// Text and surfaces that read on any background of the given lightness —
    /// what a preset falls back to once its own background is swapped for one
    /// of the opposite kind, where its text would no longer be visible.
    fileprivate mutating func neutralText(dark: Bool) {
        let ink: Color = dark ? .white : .black
        isDark = dark
        text = dark ? .white : .black.opacity(0.85)
        secondary = ink.opacity(0.55)
        tertiary = ink.opacity(dark ? 0.32 : 0.4)
        surface = ink.opacity(dark ? 0.08 : 0.05)
        surfaceHover = ink.opacity(dark ? 0.14 : 0.09)
        hairline = ink.opacity(0.10)
        icon = text
        iconInactive = tertiary
    }
}

/// The themes on offer in Settings. The raw value is what `config.json` keeps.
enum ThemePreset: String, CaseIterable, Identifiable {
    case standard
    case forroDark
    case forroLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: localized("Standard")
        case .forroDark: localized("Forró Dark")
        case .forroLight: localized("Forró Light")
        }
    }

    var palette: Palette {
        switch self {
        case .standard: .standard
        case .forroDark: .forroDark
        case .forroLight: .forroLight
        }
    }
}

extension Palette {
    /// The preset `choice` names, with whatever colours it overrides laid on
    /// top. A name this build does not know, or a colour that is not a hex
    /// value, falls back quietly: `config.json` is edited by hand, and a typo
    /// there should cost one colour, not the panel.
    init(_ choice: ThemeChoice) {
        self = (ThemePreset(rawValue: choice.preset) ?? .standard).palette

        if let hex = choice.background, let background = Color(hex: hex) {
            self.background = background
            let dark = !Palette.isLight(hex)
            if dark != isDark { neutralText(dark: dark) }
        }
        if let hex = choice.header, let header = Color(hex: hex) {
            self.header = header
            let ink: Color = Palette.isLight(hex) ? .black : .white
            headerText = ink.opacity(0.45)
            headerTextStrong = ink.opacity(0.85)
        }
        if let hex = choice.icons, let icon = Color(hex: hex) {
            self.icon = icon
            iconInactive = icon.opacity(0.45)
        }
        if let hex = choice.accent, let accent = Color(hex: hex) {
            self.accent = accent
        }
    }

    /// `#RRGGBB` or `RRGGBB`, case-insensitive; anything else is nil.
    static func components(hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// Whether dark text reads better on this colour than light text does.
    /// Relative luminance per WCAG, split where the contrast against black and
    /// against white comes out equal.
    static func isLight(_ hex: String) -> Bool {
        guard let (r, g, b) = components(hex: hex) else { return false }
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.179
    }
}

extension Color {
    init?(hex: String) {
        guard let (r, g, b) = Palette.components(hex: hex) else { return nil }
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 17 : 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Theme.clear)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }
}

/// Drawn rather than `NSSwitch`-backed: the panel is a non-activating window
/// that almost never becomes key (that is what keeps hovering it from
/// stealing focus from whatever app was in front), and `NSSwitch` renders its
/// on-state in gray rather than accent blue whenever its window is not key.
/// A plain `Color` fill has no such state to lose.
struct NotchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Theme.accent : Theme.surfaceHover)
                .frame(width: 28, height: 16)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        // Barely there on a dark panel; on a light one it is
                        // what keeps the knob of a switch that is off from
                        // melting into the track.
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .offset(x: configuration.isOn ? 6 : -6)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
