#if canImport(SwiftUI)
import GiovChatCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    init(_ rgb: GiovRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: rgb.alpha)
    }
}

/// The sRGB components of a SwiftUI colour, for choosing readable text on it; nil when they cannot be read.
@MainActor
func giovComponents(_ color: Color?) -> GiovRGB? {
    guard let color else { return nil }
    #if canImport(UIKit)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    return GiovRGB(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    #elseif canImport(AppKit)
    guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    return GiovRGB(
        red: Double(resolved.redComponent),
        green: Double(resolved.greenComponent),
        blue: Double(resolved.blueComponent),
        alpha: Double(resolved.alphaComponent)
    )
    #else
    return nil
    #endif
}

/// The resolved colours and text every part of the screen shares.
struct GiovLook {
    let palette: GiovPalette
    let strings: GiovChatStrings
    let reduceMotion: Bool
    /// The host's colour overrides, drawn as given (the palette holds their components for contrast).
    private let style: GiovChatStyle

    @MainActor
    init(style: GiovChatStyle, config: GiovWidgetConfig?, systemDark: Bool, strings: GiovChatStrings, reduceMotion: Bool) {
        let dark = giovResolveDark(override: style.theme, configured: config?.theme, systemDark: systemDark)
        let primary = giovComponents(style.primaryColor) ?? GiovRGB(hex: config?.primaryColor) ?? .defaultBrand
        palette = GiovPalette(
            dark: dark,
            primary: primary,
            background: giovComponents(style.backgroundColor),
            header: giovComponents(style.headerColor),
            visitorBubble: giovComponents(style.visitorBubbleColor),
            agentBubble: giovComponents(style.agentBubbleColor)
        )
        self.style = style
        self.strings = strings
        self.reduceMotion = reduceMotion
    }

    var dark: Bool { palette.dark }
    var primary: Color { style.primaryColor ?? Color(palette.primary) }
    var background: Color { style.backgroundColor ?? Color(palette.background) }
    var header: Color { style.headerColor ?? Color(palette.header) }
    var onHeader: Color { Color(palette.onHeader) }
    var button: Color { primary }
    var onButton: Color { Color(palette.onButton) }
    var composer: Color { background }
    var divider: Color { Color(palette.divider) }
    var inputFill: Color { Color(palette.inputFill) }
    var inputBorder: Color { Color(palette.inputBorder) }
    var text: Color { Color(palette.text) }
    var secondaryText: Color { Color(palette.secondaryText) }
    var hint: Color { Color(palette.hint) }
    var error: Color { Color(palette.error) }
    var skeleton: Color { Color(palette.skeleton) }

    /// The colours inside a visitor's or an agent's bubble.
    func bubble(visitor: Bool) -> GiovBubbleColors {
        let resolved = palette.bubble(visitor: visitor)
        let override = visitor ? style.visitorBubbleColor : style.agentBubbleColor
        return GiovBubbleColors(
            fill: override ?? Color(resolved.fill),
            text: Color(resolved.text),
            subtle: Color(resolved.subtle),
            faint: Color(resolved.faint),
            accent: Color(resolved.accent),
            code: Color(resolved.code),
            imageFill: Color(resolved.imageFill)
        )
    }
}

struct GiovBubbleColors {
    let fill: Color
    let text: Color
    let subtle: Color
    let faint: Color
    let accent: Color
    let code: Color
    let imageFill: Color
}

/// Announces `text` to VoiceOver (iOS), e.g. an error that appears.
@MainActor
func giovAnnounce(_ text: String) {
    #if canImport(UIKit) && !os(watchOS)
    UIAccessibility.post(notification: .announcement, argument: text)
    #endif
}
#endif
