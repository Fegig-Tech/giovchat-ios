import Foundation
@testable import GiovChat
import GiovChatCore
import Testing

@Suite struct ColorTests {
    @Test func brandColoursParseLikeTheAndroidSDK() {
        #expect(GiovRGB(hex: "#0ea5e9") == GiovRGB(rgb: 0x0EA5E9))
        #expect(GiovRGB(hex: "0EA5E9") == GiovRGB(rgb: 0x0EA5E9))
        #expect(GiovRGB(hex: " #fff ") == GiovRGB(rgb: 0xFFFFFF))
        #expect(GiovRGB(hex: "#800ea5e9") == GiovRGB(rgb: 0x0EA5E9, alpha: Double(0x80) / 255), "#aarrggbb")
        #expect(GiovRGB(hex: "#12345") == nil)
        #expect(GiovRGB(hex: "#ggg") == nil)
        #expect(GiovRGB(hex: "") == nil)
        #expect(GiovRGB(hex: nil) == nil)
        #expect(GiovRGB(hex: "rgb(1,2,3)") == nil)
    }

    @Test func textOnAColourIsNearBlackOrWhiteWhicheverReads() {
        #expect(GiovRGB.white.readableForeground == .ink)
        #expect(GiovRGB(rgb: 0xF0F0F0).readableForeground == .ink)
        #expect(GiovRGB(rgb: 0xFACC15).readableForeground == .ink, "yellow")
        #expect(GiovRGB.defaultBrand.readableForeground == .white)
        #expect(GiovRGB(rgb: 0x0369A1).readableForeground == .white, "deep sky")
        #expect(GiovRGB.black.readableForeground == .white)
        #expect(abs(GiovRGB.white.luminance - 1) < 0.0001)
        #expect(GiovRGB.black.luminance == 0)
    }

    @Test func theThemeIsTheOverrideThenTheDashboardThenLight() {
        #expect(!giovResolveDark(override: nil, configured: nil, systemDark: true))
        #expect(giovResolveDark(override: nil, configured: .dark, systemDark: false))
        #expect(giovResolveDark(override: nil, configured: .auto, systemDark: true))
        #expect(!giovResolveDark(override: nil, configured: .auto, systemDark: false))
        #expect(!giovResolveDark(override: .light, configured: .dark, systemDark: true))
        #expect(giovResolveDark(override: .auto, configured: .light, systemDark: true))
    }

    @Test func thePaletteFollowsTheBrandAndTheTheme() {
        let light = GiovPalette(dark: false, primary: .defaultBrand)
        #expect(light.background == .white)
        #expect(light.header == .defaultBrand)
        #expect(light.onHeader == .white)
        #expect(light.visitorBubble == .defaultBrand)
        #expect(light.onVisitorBubble == .white)
        #expect(light.agentBubble == GiovRGB(rgb: 0xF0F0F0))
        #expect(light.onAgentBubble == .ink)
        #expect(light.error == GiovRGB(rgb: 0xDC2626))

        let dark = GiovPalette(dark: true, primary: GiovRGB(rgb: 0xFACC15))
        #expect(dark.background == GiovRGB(rgb: 0x0A0A0A))
        #expect(dark.onHeader == .ink, "a light brand gets dark text")
        #expect(dark.onButton == .ink)
        #expect(dark.agentBubble == GiovRGB(rgb: 0x242424))
        #expect(dark.onAgentBubble == GiovRGB(rgb: 0xF0F0F0))
    }

    @Test func overridesWinAndKeepTextReadable() {
        let palette = GiovPalette(
            dark: false,
            primary: .defaultBrand,
            background: GiovRGB(rgb: 0xF8FAFC),
            header: GiovRGB(rgb: 0x0F172A),
            visitorBubble: GiovRGB(rgb: 0xE0F2FE),
            agentBubble: GiovRGB(rgb: 0x1E293B)
        )
        #expect(palette.background == GiovRGB(rgb: 0xF8FAFC))
        #expect(palette.composer == palette.background)
        #expect(palette.onHeader == .white)
        #expect(palette.onVisitorBubble == .ink)
        #expect(palette.onAgentBubble == .white)
        #expect(palette.button == .defaultBrand)
    }

    @Test func bubbleOverlaysDependOnHowDarkTheBubbleIs() {
        let palette = GiovPalette(dark: false, primary: .defaultBrand)
        let visitor = palette.bubble(visitor: true)
        #expect(visitor.isDark)
        #expect(visitor.text == .white)
        #expect(visitor.subtle.contrast(with: visitor.fill) >= 4.5)
        #expect(visitor.code == GiovRGB.white.withAlpha(0.18))
        let agent = palette.bubble(visitor: false)
        #expect(!agent.isDark)
        #expect(agent.text == .ink)
        #expect(agent.accent == GiovRGB.black.withAlpha(0.2))
        #expect(GiovPalette(dark: true, primary: .defaultBrand).bubble(visitor: false).isDark)
    }
}

@Suite struct MarkdownTextTests {
    private func runs(_ text: AttributedString) -> [(String, InlinePresentationIntent?, URL?, Bool)] {
        text.runs.map { run in
            (String(text[run.range].characters), run.inlinePresentationIntent, run.link, run[GiovUnderlineAttribute.self] ?? false)
        }
    }

    @Test func marksBecomeFoundationIntents() {
        let lines = GiovChatMarkdown.parse("Hi **bold** *it* `code` ~~gone~~ <u>under</u>")
        guard case .paragraph(let paragraph) = lines.first else {
            Issue.record("expected a paragraph")
            return
        }
        let text = giovInlineAttributedString(paragraph)
        #expect(String(text.characters) == "Hi bold it code gone under")
        let pieces = runs(text)
        #expect(pieces.contains { $0.0 == "bold" && $0.1 == .stronglyEmphasized })
        #expect(pieces.contains { $0.0 == "it" && $0.1 == .emphasized })
        #expect(pieces.contains { $0.0 == "code" && $0.1 == .code })
        #expect(pieces.contains { $0.0 == "gone" && $0.1 == .strikethrough })
        #expect(pieces.contains { $0.0 == "under" && $0.1 == nil && $0.3 })
        #expect(pieces.contains { $0.0 == "Hi " && $0.1 == nil && !$0.3 })
    }

    @Test func nestedMarksCombine() {
        let text = giovInlineAttributedString([GiovChatMarkdown.parseInline("**_both_**")])
        #expect(runs(text).contains { $0.1 == [.stronglyEmphasized, .emphasized] })
    }

    @Test func onlyHttpAndMailtoLinksAreTappableAndUnderlined() {
        let text = giovInlineAttributedString([
            GiovChatMarkdown.parseInline("[docs](https://giovchat.app/docs) and mail@x.test via [mail](mailto:help@giovchat.app)"),
        ])
        let pieces = runs(text)
        #expect(pieces.contains { $0.0 == "docs" && $0.2 == URL(string: "https://giovchat.app/docs") && $0.3 })
        #expect(pieces.contains { $0.0 == "mail" && $0.2 == URL(string: "mailto:help@giovchat.app") && $0.3 })
        let unsafe = [GiovInlineRun(text: "click", href: "javascript:alert(1)"), GiovInlineRun(text: " file", href: "file:///etc/passwd")]
        let plain = runs(giovInlineAttributedString([unsafe]))
        #expect(plain.allSatisfy { $0.2 == nil && !$0.3 })
        #expect(plain.map(\.0).joined() == "click file")
    }

    @Test func bareLinksAreDetected() {
        let text = giovInlineAttributedString([GiovChatMarkdown.parseInline("see https://giovchat.app/pricing.")])
        #expect(runs(text).contains { $0.2 == URL(string: "https://giovchat.app/pricing") })
        #expect(String(text.characters) == "see https://giovchat.app/pricing.")
    }

    @Test func linesJoinWithLineBreaks() {
        let blocks = GiovChatMarkdown.parse("one\ntwo")
        guard case .paragraph(let lines) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(giovInlineAttributedString(lines).characters) == "one\ntwo")
    }

    @Test func theDecoratorSeesEveryPieceWithItsMarks() {
        var seen: [(Bool, Bool)] = []
        _ = giovInlineAttributedString([GiovChatMarkdown.parseInline("a `b` [c](https://x.test)")]) { _, marks, isLink in
            seen.append((marks.code, isLink))
        }
        #expect(seen.contains { $0.0 && !$0.1 })
        #expect(seen.contains { !$0.0 && $0.1 })
        #expect(seen.count == 4)
    }

    @Test func listMarkersFollowTheListStart() {
        guard case .list(let ordered) = GiovChatMarkdown.parse("3. a\n4. b").first,
              case .list(let bullets) = GiovChatMarkdown.parse("- a\n- b").first
        else {
            Issue.record("expected lists")
            return
        }
        #expect(giovListMarker(ordered, index: 0) == "3.")
        #expect(giovListMarker(ordered, index: 1) == "4.")
        #expect(giovListMarker(bullets, index: 1) == "•")
    }
}
