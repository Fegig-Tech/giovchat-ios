import Foundation
@testable import GiovChat
import GiovChatCore
import Testing

@Suite struct BrandingRulesTests {
    @Test func noOverridesKeepTheDefaults() {
        let colors = giovResolveBranding(text: nil, brand: nil, background: nil)
        #expect(colors.text == giovBrandingDefaultText && colors.brand == giovBrandingDefaultBrand)
        #expect(colors.background == giovBrandingDefaultBackground && !colors.customBackground && colors.warnings.isEmpty)
    }

    @Test func readableOverridesAreApplied() {
        let dark = GiovRGB(rgb: 0x111827)
        let colors = giovResolveBranding(text: GiovRGB(rgb: 0xF9FAFB), brand: GiovRGB(rgb: 0xFBBF24), background: dark)
        #expect(colors.background == dark && colors.customBackground)
        #expect(colors.text == GiovRGB(rgb: 0xF9FAFB) && colors.brand == GiovRGB(rgb: 0xFBBF24))
        #expect(colors.warnings.isEmpty)
        #expect(giovResolveBranding(text: GiovRGB(rgb: 0x000000), brand: nil, background: nil).text == GiovRGB(rgb: 0x000000))
    }

    @Test func lowContrastFallsBackToTheDefaultAndWarns() {
        let colors = giovResolveBranding(text: GiovRGB(rgb: 0xDDDDDD), brand: GiovRGB(rgb: 0xFFFF00), background: nil)
        #expect(colors.text == giovBrandingDefaultText && colors.brand == giovBrandingDefaultBrand)
        #expect(colors.warnings.count == 2)
    }

    @Test func whenTheDefaultAlsoFailsTheTextIsBlackOrWhite() {
        // Default text #52525B and link #7C3AED are too dark on a near-black background.
        let colors = giovResolveBranding(text: GiovRGB(rgb: 0x222222), brand: nil, background: GiovRGB(rgb: 0x0A0A0A))
        #expect(colors.text == GiovRGB(rgb: 0x0A0A0A).readableForeground)
        #expect(colors.brand == GiovRGB(rgb: 0x0A0A0A).readableForeground)
        #expect(colors.text.contrast(with: colors.background) >= 4.5)
    }

    @Test func alphaIsIgnored() {
        let translucentBackground = giovResolveBranding(text: nil, brand: nil, background: GiovRGB(rgb: 0x000000, alpha: 0.5))
        #expect(translucentBackground.background == giovBrandingDefaultBackground && !translucentBackground.customBackground)
        #expect(translucentBackground.warnings.count == 1)
        let translucentText = giovResolveBranding(text: GiovRGB(rgb: 0x000000, alpha: 0.9), brand: GiovRGB(rgb: 0x000000, alpha: 0.2), background: nil)
        #expect(translucentText.text == giovBrandingDefaultText && translucentText.brand == giovBrandingDefaultBrand)
    }

    @Test func theAAThresholdIsExact() {
        #expect(giovResolveBranding(text: GiovRGB(rgb: 0x767676), brand: nil, background: nil).text == GiovRGB(rgb: 0x767676), "4.54:1 passes")
        #expect(giovResolveBranding(text: GiovRGB(rgb: 0x777777), brand: nil, background: nil).text == giovBrandingDefaultText, "4.48:1 fails")
    }

    @Test func theFooterIsHiddenOnlyWhenTheServerSaysSo() {
        func config(_ show: Bool) -> GiovWidgetConfig { GiovWidgetConfig(title: "A", showBranding: show) }
        #expect(giovShowsBranding(explicit: nil, config: config(true), phase: .active))
        #expect(!giovShowsBranding(explicit: nil, config: config(false), phase: .active))
        #expect(!giovShowsBranding(explicit: nil, config: nil, phase: .loading), "nothing while the configuration loads")
        #expect(giovShowsBranding(explicit: nil, config: nil, phase: .error), "a failed configuration keeps it")
        #expect(giovShowsBranding(explicit: true, config: config(false), phase: .active), "an explicit value wins")
        #expect(!giovShowsBranding(explicit: false, config: config(true), phase: .active))
    }
}
