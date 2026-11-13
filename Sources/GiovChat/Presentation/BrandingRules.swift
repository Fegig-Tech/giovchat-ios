import Foundation
import GiovChatCore

// The "Powered by GiovChat" footer follows the app's style but stays on: its colours are the host's only while they
// stay readable (WCAG AA), and only the server's `showBranding: false` removes it. Pure rules, no UI framework, so
// they are tested on every platform.

/// The footer's default text colour.
let giovBrandingDefaultText = GiovRGB(rgb: 0x52525B)
/// The footer's default "GiovChat" colour.
let giovBrandingDefaultBrand = GiovRGB(rgb: 0x7C3AED)
/// The footer's default background.
let giovBrandingDefaultBackground = GiovRGB(rgb: 0xFFFFFF)
/// The WCAG AA contrast for small text.
let giovBrandingMinimumContrast = 4.5

/// What the footer draws after the host's overrides were checked.
struct GiovBrandingColors: Sendable, Equatable {
    var text: GiovRGB
    var brand: GiovRGB
    var background: GiovRGB
    /// The host set a background: the divider turns translucent grey instead of #EBEBEB.
    var customBackground: Bool
    /// One line per rejected override, for the developer's console.
    var warnings: [String]
}

/// Checks the host's colours. The background is used only when opaque. Text and link colours are used only when opaque
/// and at least 4.5:1 against the effective background; otherwise the property's default, and when the default fails
/// on that background too, black or white (whichever reads).
func giovResolveBranding(text: GiovRGB?, brand: GiovRGB?, background: GiovRGB?) -> GiovBrandingColors {
    var warnings: [String] = []
    var effective = giovBrandingDefaultBackground
    var custom = false
    if let background {
        if background.alpha >= 1 {
            effective = background
            custom = true
        } else {
            warnings.append("GiovBrandingStyle.backgroundColor is translucent; the footer keeps a white background.")
        }
    }

    func pick(_ value: GiovRGB?, fallback: GiovRGB, name: String) -> GiovRGB {
        func readable(_ color: GiovRGB) -> Bool { color.alpha >= 1 && color.contrast(with: effective) >= giovBrandingMinimumContrast }
        if let value {
            if readable(value) { return value }
            warnings.append("GiovBrandingStyle.\(name) is translucent or below 4.5:1 contrast on the footer background; using the default.")
        }
        return readable(fallback) ? fallback : effective.readableForeground
    }

    return GiovBrandingColors(
        text: pick(text, fallback: giovBrandingDefaultText, name: "textColor"),
        brand: pick(brand, fallback: giovBrandingDefaultBrand, name: "brandColor"),
        background: effective,
        customBackground: custom,
        warnings: warnings
    )
}

/// Whether the footer shows: an explicit value wins, then the workspace's `showBranding`; only an explicit `false`
/// from the server removes it. While the configuration has not loaded nothing is drawn, unless the chat failed
/// (then the footer shows, as a failed configuration keeps it).
func giovShowsBranding(explicit: Bool?, config: GiovWidgetConfig?, phase: GiovChatPhase) -> Bool {
    if let explicit { return explicit }
    if let config { return config.showBranding }
    return phase == .error
}
