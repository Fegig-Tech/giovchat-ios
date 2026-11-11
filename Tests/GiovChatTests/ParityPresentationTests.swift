import Foundation
@testable import GiovChat
import GiovChatCore
import Testing

// The screen's share of the behaviour every Giov SDK has (see each test).

private let strings = GiovChatStrings.en

private func agent(_ id: String, _ content: String, isBot: Bool = false, senderName: String? = "Ada", isStreaming: Bool = false) -> GiovMessage {
    GiovMessage(
        id: id, role: .agent, content: content, createdAt: 1_700_000_000_000, isBot: isBot, senderName: senderName,
        clientMessageId: isStreaming ? "stream:\(id)" : nil, isStreaming: isStreaming
    )
}

private func state(_ messages: [GiovMessage], reconnecting: Bool = false, error: GiovChatError? = nil) -> GiovChatUiState {
    var value = GiovChatUiState()
    value.phase = .active
    value.config = GiovWidgetConfig(title: "Acme", botEnabled: true, botName: "Atlas")
    value.messages = messages
    value.reconnecting = reconnecting
    value.error = error
    return value
}

@Suite struct ParityPresentationTests {
    @Test func aLostConnectionShowsReconnectingUnlessThereIsAFailureToShow() {
        #expect(giovBannerText(state([]), strings: strings) == nil)
        #expect(giovBannerText(state([], reconnecting: true), strings: strings) == "Connection lost. Reconnecting…")
        let busy = GiovChatError(.workspaceBusy, "busy")
        #expect(giovBannerText(state([], reconnecting: true, error: busy), strings: strings) == strings.busy)
    }

    @Test func newRepliesAreAnnouncedOnceHistoryIsNotAndADraftOnlyWhenSaved() {
        var announcer = GiovMessageAnnouncer()
        let history = [agent("h1", "Earlier"), agent("h2", "Older")]
        #expect(announcer.update(state(history), strings: strings) == nil, "what is on screen at first is not read out")
        #expect(announcer.update(state(history + [agent("a1", "Hello there")]), strings: strings) == "Ada: Hello there")
        #expect(announcer.update(state(history + [agent("a1", "Hello there")]), strings: strings) == nil, "once")
        let draft = agent("s1", "Thinking", isBot: true, isStreaming: true)
        #expect(announcer.update(state(history + [agent("a1", "Hello there"), draft]), strings: strings) == nil)
        var saved = agent("s-saved", "Done thinking", isBot: true)
        saved.clientMessageId = "stream:s1"
        #expect(announcer.update(state(history + [agent("a1", "Hello there"), saved]), strings: strings) == "Atlas: Done thinking")
        let visitor = GiovMessage(id: "v1", role: .visitor, content: "Mine", createdAt: 1)
        #expect(announcer.update(state(history + [visitor]), strings: strings) == nil, "the visitor's own messages are not")
        let batch = (0..<5).map { agent("c\($0)", "Caught up \($0)") }
        #expect(announcer.update(state(batch), strings: strings) == nil, "a catch-up batch is not read out")
    }

    @Test func textOnTheBrandColourPicksTheHigherWCAGContrast() {
        // A luminance threshold of 0.6 gave white on mid greens at about 2.3:1.
        let green = GiovRGB(rgb: 0x22C55E)
        #expect(green.readableForeground == .ink)
        #expect(green.readableForeground.contrast(with: green) >= 4.5)
        for value: UInt32 in [0x7C3AED, 0x0EA5E9, 0x22C55E, 0xF97316, 0xEF4444, 0x10B981, 0x6366F1, 0xFACC15, 0x176BFF, 0x808080, 0x000000, 0xFFFFFF] {
            let colour = GiovRGB(rgb: value)
            let chosen = colour.readableForeground.contrast(with: colour)
            #expect(chosen >= GiovRGB.white.contrast(with: colour) && chosen >= GiovRGB.ink.contrast(with: colour) - 0.0001, "\(String(value, radix: 16))")
        }
        #expect(abs(GiovRGB.white.contrast(with: .black) - 21) < 0.001)
    }

    @Test func senderLabelsAndTimesMeetAAOnEveryBubble() {
        var palettes = [GiovPalette(dark: false, primary: .defaultBrand), GiovPalette(dark: true, primary: .defaultBrand)]
        for value: UInt32 in [0x22C55E, 0xFACC15, 0x0EA5E9, 0x176BFF, 0x808080] {
            palettes.append(GiovPalette(dark: false, primary: GiovRGB(rgb: value)))
            palettes.append(GiovPalette(dark: true, primary: GiovRGB(rgb: value), agentBubble: GiovRGB(rgb: value)))
        }
        for palette in palettes {
            for visitor in [true, false] {
                let bubble = palette.bubble(visitor: visitor)
                #expect(bubble.subtle.contrast(with: bubble.fill) >= 4.5, "label on \(bubble.fill)")
                #expect(bubble.faint.contrast(with: bubble.fill) >= 4.5, "time on \(bubble.fill)")            }
        }
    }

    @Test func theTextFieldStaysEditableWhileFilesUploadOnlySendWaits() {
        for phase in [GiovChatPhase.ready, .connecting, .active] {
            #expect(GiovComposerRules.textEditable(phase))
            #expect(!GiovComposerRules.canSend(phase: phase, sending: true, busy: false, text: "hi", fileCount: 0))
        }
        #expect(!GiovComposerRules.textEditable(.error))
    }

    @Test func theMenuLinksToTheWorkspacesPrivacyPolicyElseGiovs() {
        #expect(giovPrivacyPolicyURL(nil).absoluteString == "https://giovchat.app/privacy")
        let own = GiovWidgetConfig(title: "Acme", privacyPolicyURL: "https://acme.test/privacy")
        #expect(giovPrivacyPolicyURL(own).absoluteString == "https://acme.test/privacy")
        let odd = GiovWidgetConfig(title: "Acme", privacyPolicyURL: "javascript:alert(1)")
        #expect(giovPrivacyPolicyURL(odd) == giovDefaultPrivacyPolicyURL)
        #expect(GiovChatStrings.all.values.allSatisfy { !$0.privacyPolicy.isEmpty && !$0.moreOptions.isEmpty })
    }
}
