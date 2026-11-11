import Foundation
import GiovChatCore

/// An sRGB colour with components from 0 to 1, independent of any UI framework.
struct GiovRGB: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ value: Double) -> Double { min(max(value.isFinite ? value : 0, 0), 1) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
        self.alpha = clamp(alpha)
    }

    /// `0xRRGGBB`.
    init(rgb value: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// `#rgb`, `#rrggbb` or `#aarrggbb` (the leading `#` is optional), as the Android SDK reads the dashboard's
    /// colour; nil for anything else.
    init?(hex value: String?) {
        var hex = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6 { hex = "ff" + hex }
        guard hex.count == 8, let argb = UInt32(hex, radix: 16) else { return nil }
        self.init(rgb: argb & 0xFF_FFFF, alpha: Double(argb >> 24) / 255)
    }

    /// The same colour at `alpha`.
    func withAlpha(_ alpha: Double) -> GiovRGB {
        GiovRGB(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// WCAG relative luminance, 0 (black) to 1 (white); alpha is ignored.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two opaque colours, 1 to 21.
    func contrast(with other: GiovRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A light colour: near-black text has a higher WCAG contrast on it than white.
    var isLight: Bool { contrast(with: .ink) > contrast(with: .white) }

    /// Near-black or white, whichever has the higher WCAG contrast on this colour. (The web widget always draws white
    /// on the brand colour; the former fixed threshold, luminance above 0.6, gave white on mid greens at about 2.3:1.)
    var readableForeground: GiovRGB { isLight ? .ink : .white }

    /// This colour mixed with `other` by `amount` (0 keeps this one), opaque.
    func mixed(with other: GiovRGB, _ amount: Double) -> GiovRGB {
        GiovRGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    /// A quieter version of this text colour on `fill`: moved toward the fill by up to `amount`, as far as it still
    /// meets `minimum` contrast. For small secondary text such as sender labels and times.
    func muted(on fill: GiovRGB, by amount: Double, minimum: Double = 4.5) -> GiovRGB {
        var step = amount
        while step > 0.001 {
            let candidate = mixed(with: fill, step)
            if candidate.contrast(with: fill) >= minimum { return candidate }
            step -= 0.05
        }
        return withAlpha(1)
    }

    static let white = GiovRGB(rgb: 0xFFFFFF)
    static let black = GiovRGB(rgb: 0x000000)
    static let ink = GiovRGB(rgb: 0x111111)
    /// The widget's default brand colour, used when the configured one cannot be read.
    static let defaultBrand = GiovRGB(rgb: 0x7C3AED)
}

/// `light`, `dark` or `auto`: the override wins, then the dashboard; light until the configuration has loaded.
func giovResolveDark(override: GiovThemeMode?, configured: GiovThemeMode?, systemDark: Bool) -> Bool {
    switch override ?? configured ?? .light {
    case .light: return false
    case .dark: return true
    case .auto: return systemDark
    }
}

/// Every colour of the chat screen, resolved from the theme, the brand colour and the host's overrides. Matches the
/// Android and Flutter screens.
struct GiovPalette: Sendable, Equatable {
    var dark: Bool
    var primary: GiovRGB
    var background: GiovRGB
    var header: GiovRGB
    var onHeader: GiovRGB
    var button: GiovRGB
    var onButton: GiovRGB
    var visitorBubble: GiovRGB
    var onVisitorBubble: GiovRGB
    var agentBubble: GiovRGB
    var onAgentBubble: GiovRGB
    var composer: GiovRGB
    var divider: GiovRGB
    var inputFill: GiovRGB
    var inputBorder: GiovRGB
    var text: GiovRGB
    var secondaryText: GiovRGB
    var hint: GiovRGB
    var error: GiovRGB
    var skeleton: GiovRGB

    /// - Parameters:
    ///   - primary: the brand colour (the override, else the dashboard's).
    ///   - background, header, visitorBubble, agentBubble: the host's overrides, when given.
    init(
        dark: Bool,
        primary: GiovRGB,
        background: GiovRGB? = nil,
        header: GiovRGB? = nil,
        visitorBubble: GiovRGB? = nil,
        agentBubble: GiovRGB? = nil
    ) {
        self.dark = dark
        self.primary = primary
        self.background = background ?? (dark ? GiovRGB(rgb: 0x0A0A0A) : .white)
        self.header = header ?? primary
        onHeader = self.header.readableForeground
        button = primary
        onButton = primary.readableForeground
        self.visitorBubble = visitorBubble ?? primary
        onVisitorBubble = self.visitorBubble.readableForeground
        text = dark ? GiovRGB(rgb: 0xF0F0F0) : .ink
        self.agentBubble = agentBubble ?? (dark ? GiovRGB(rgb: 0x242424) : GiovRGB(rgb: 0xF0F0F0))
        onAgentBubble = agentBubble?.readableForeground ?? text
        composer = self.background
        divider = dark ? GiovRGB(rgb: 0x1E1E1E) : GiovRGB(rgb: 0xEBEBEB)
        inputFill = dark ? GiovRGB(rgb: 0x1C1C1C) : GiovRGB(rgb: 0xF5F5F5)
        inputBorder = dark ? GiovRGB(rgb: 0x2E2E2E) : GiovRGB(rgb: 0xE5E5E5)
        secondaryText = dark ? GiovRGB(rgb: 0xAAAAAA) : GiovRGB(rgb: 0x555555)
        hint = dark ? GiovRGB(rgb: 0x8A8A8A) : GiovRGB(rgb: 0x777777)
        // A lighter red on the dark surface keeps the contrast above 4.5:1.
        error = dark ? GiovRGB(rgb: 0xF87171) : GiovRGB(rgb: 0xDC2626)
        skeleton = dark ? GiovRGB(rgb: 0x1C1C1C) : GiovRGB(rgb: 0xF0F0F0)
    }

    /// The colours inside one bubble.
    struct Bubble: Sendable, Equatable {
        var fill: GiovRGB
        var text: GiovRGB
        /// Sender label.
        var subtle: GiovRGB
        /// Timestamp.
        var faint: GiovRGB
        /// Quote bars and rules.
        var accent: GiovRGB
        /// Behind code.
        var code: GiovRGB
        /// Image boxes before the picture loads; file row borders use ``accent``.
        var imageFill: GiovRGB
        /// The bubble is dark, so overlays are light.
        var isDark: Bool
    }

    func bubble(visitor: Bool) -> Bubble {
        let fill = visitor ? visitorBubble : agentBubble
        let text = visitor ? onVisitorBubble : onAgentBubble
        let isDark = visitor ? !visitorBubble.isLight : !agentBubble.isLight
        return Bubble(
            fill: fill,
            text: text,
            // Sender labels and times are small text: at least 4.5:1 on the bubble (WCAG AA).
            subtle: text.muted(on: fill.withAlpha(1), by: 0.35),
            faint: text.muted(on: fill.withAlpha(1), by: 0.45),
            accent: isDark ? GiovRGB.white.withAlpha(0.5) : GiovRGB.black.withAlpha(0.2),
            code: isDark ? GiovRGB.white.withAlpha(0.18) : GiovRGB.black.withAlpha(0.06),
            imageFill: isDark ? GiovRGB(rgb: 0x1F1F1F) : GiovRGB(rgb: 0xECECEC),
            isDark: isDark
        )
    }
}
