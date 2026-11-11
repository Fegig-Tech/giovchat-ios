import Foundation
@testable import GiovChat
import GiovChatCore
import Testing

private let strings = GiovChatStrings.en

private func config(
    title: String = "Acme support",
    botEnabled: Bool = true,
    botName: String? = "Atlas",
    attachments: GiovAttachmentPolicy? = nil
) -> GiovWidgetConfig {
    GiovWidgetConfig(title: title, botEnabled: botEnabled, botName: botName, attachments: attachments)
}

private func state(
    phase: GiovChatPhase,
    config: GiovWidgetConfig? = config(),
    header: GiovHeaderIdentity? = nil,
    error: GiovChatError? = nil,
    hasConversation: Bool = false
) -> GiovChatUiState {
    var value = GiovChatUiState()
    value.phase = phase
    value.config = config
    value.header = header ?? config.map { giovHeaderIdentity($0) }
    value.error = error
    value.hasConversation = hasConversation
    return value
}

private func message(
    id: String = "m1",
    role: GiovRole = .agent,
    content: String = "Hello",
    isBot: Bool = false,
    isAutomated: Bool = false,
    senderName: String? = nil,
    delivery: GiovDelivery = .sent,
    clientMessageId: String? = nil,
    streamId: String? = nil,
    isStreaming: Bool = false
) -> GiovMessage {
    GiovMessage(
        id: id, role: role, content: content, createdAt: 1_700_000_000_000, isBot: isBot, isAutomated: isAutomated,
        senderName: senderName, delivery: delivery, clientMessageId: clientMessageId, streamId: streamId,
        isStreaming: isStreaming
    )
}

@Suite struct ScreenTests {
    @Test func everyPhaseMapsToItsScreen() {
        #expect(GiovScreenContent(state(phase: .loading, config: nil), strings: strings) == .skeleton)
        #expect(GiovScreenContent(state(phase: .idle), strings: strings) == .skeleton)
        #expect(GiovScreenContent(state(phase: .preChat), strings: strings) == .preChat)
        #expect(GiovScreenContent(state(phase: .ready), strings: strings) == .conversation)
        #expect(GiovScreenContent(state(phase: .connecting), strings: strings) == .conversation)
        #expect(GiovScreenContent(state(phase: .active), strings: strings) == .conversation)
    }

    @Test func errorsShowATranslatedSentenceNeverServerText() {
        let busy = GiovChatError(.workspaceBusy, "server said no", status: 503, code: "workspace_busy")
        #expect(GiovScreenContent(state(phase: .error, error: busy), strings: strings) == .error(strings.busy))
        #expect(GiovScreenContent(state(phase: .error), strings: strings) == .error(strings.unavailable))
        #expect(GiovScreenContent(state(phase: .error, error: busy), strings: .fr) == .error(GiovChatStrings.fr.busy))
    }
}

@Suite struct HeaderTests {
    @Test func theHeaderShowsWhoAnswersWithAStatusPerPhase() {
        let bot = GiovHeaderModel(state(phase: .active), strings: strings)
        #expect(bot.title == "Atlas")
        #expect(bot.kind == .bot)
        #expect(bot.subtitle == strings.statusBot)
        #expect(bot.initial == "A")

        let connecting = GiovHeaderModel(state(phase: .connecting), strings: strings)
        #expect(connecting.subtitle == strings.connecting)
        #expect(GiovHeaderModel(state(phase: .ready), strings: strings).subtitle == strings.statusBot)
        #expect(GiovHeaderModel(state(phase: .loading), strings: strings).subtitle == nil)
        #expect(GiovHeaderModel(state(phase: .error), strings: strings).subtitle == nil)
    }

    @Test func aPersonWinsThenTheBotThenTheTeam() {
        let person = GiovHeaderIdentity(kind: .person, title: " élodie", avatar: "https://cdn.test/e.png")
        let model = GiovHeaderModel(state(phase: .active, header: person), strings: strings)
        #expect(model.kind == .person)
        #expect(model.subtitle == strings.statusPerson)
        #expect(model.avatarURL == "https://cdn.test/e.png")
        #expect(model.initial == "É")

        let team = GiovHeaderModel(state(phase: .active, config: config(botEnabled: false)), strings: strings)
        #expect(team.title == "Acme support")
        #expect(team.subtitle == strings.statusTeam)
    }

    @Test func beforeTheConfigurationLoadsTheTitleIsGenericAndOnlyHttpAvatarsLoad() {
        let loading = GiovHeaderModel(state(phase: .loading, config: nil), strings: strings)
        #expect(loading.title == "Chat")
        #expect(loading.kind == nil)
        let unsafe = GiovHeaderIdentity(kind: .person, title: "Ada", avatar: "file:///etc/passwd")
        #expect(GiovHeaderModel(state(phase: .active, header: unsafe), strings: strings).avatarURL == nil)
        let blank = GiovHeaderIdentity(kind: .team, title: "  ")
        #expect(GiovHeaderModel(state(phase: .active, header: blank), strings: strings).initial == "")
    }

    @Test func theBotNameComesFromTheConfigElseTheBotHeader() {
        #expect(giovBotName(state(phase: .active)) == "Atlas")
        var unnamed = state(phase: .active, config: config(botName: nil))
        unnamed.header = GiovHeaderIdentity(kind: .bot, title: "Helper")
        #expect(giovBotName(unnamed) == "Helper")
        #expect(giovBotName(state(phase: .active, config: config(botEnabled: false, botName: nil))) == nil)
    }

    @Test func theTypingLabelNamesTheBotOnlyWhenTheServerSaidSo() {
        #expect(giovTypingLabel(isBot: true, botName: "Atlas", strings: strings) == "Atlas is typing")
        #expect(giovTypingLabel(isBot: true, botName: "  ", strings: strings) == "GiovBot is typing")
        #expect(giovTypingLabel(isBot: nil, botName: "Atlas", strings: strings) == strings.teamTyping)
        #expect(giovTypingLabel(isBot: false, botName: "Atlas", strings: strings) == strings.teamTyping)
    }
}

@Suite struct BubbleTests {
    private func model(_ message: GiovMessage, agentName: String? = nil) -> GiovBubbleModel {
        GiovBubbleModel(message, strings: strings, botName: "Atlas", agentName: agentName, time: { _ in "10:42" })
    }

    @Test func labelsSidesAndTheBotMark() {
        let bot = model(message(isBot: true, isAutomated: true))
        #expect(bot.senderLabel == "Atlas")
        #expect(bot.showsBotMark)
        #expect(!bot.isVisitor)
        #expect(bot.footer == "10:42")

        let person = model(message(senderName: "Ada"))
        #expect(person.senderLabel == "Ada")
        #expect(!person.showsBotMark)
        #expect(model(message(), agentName: "Grace").senderLabel == "Grace")
        #expect(model(message(isAutomated: true)).senderLabel == strings.automated)

        let visitor = model(message(role: .visitor))
        #expect(visitor.isVisitor)
        #expect(visitor.senderLabel == strings.you)
        #expect(!visitor.showsBotMark)
    }

    @Test func sendingShowsSendingAndAStreamingDraftHasNoFooterUntilSaved() {
        let sending = model(message(role: .visitor, delivery: .sending, clientMessageId: "c1"))
        #expect(sending.footer == strings.sending)
        #expect(sending.isSending)
        #expect(sending.failureText == nil)

        let draft = message(id: "stream:s1", isBot: true, isAutomated: true, clientMessageId: "stream:s1", streamId: "s1", isStreaming: true)
        let saved = message(id: "srv-9", isBot: true, streamId: "s1")
        #expect(model(draft).footer == nil)
        #expect(model(saved).footer == "10:42")
        #expect(model(draft).key == model(saved).key, "the saved reply replaces the draft in place")
    }

    @Test func aFailedMessageOffersRetryAndDiscard() {
        let failed = model(message(role: .visitor, delivery: .failed, clientMessageId: "c1"))
        #expect(failed.failureText == "Not sent · Tap to retry")
        #expect(failed.clientMessageId == "c1")
        #expect(!failed.isSending)
        let unknown = model(message(role: .visitor, delivery: .failed))
        #expect(unknown.failureText == "Not sent")
        #expect(model(message(delivery: .failed)).failureText == nil, "only visitor messages fail")
    }

    @Test func timeLabelsUseTheDeviceFormat() {
        let utc = TimeZone(identifier: "UTC")!
        let ms = 1_700_000_000_000 // 2023-11-14 22:13:20 UTC
        let english = giovTimeLabel(ms, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(english.contains("10:13"))
        #expect(english.contains("PM"))
        let german = giovTimeLabel(ms, locale: Locale(identifier: "de_DE"), timeZone: utc)
        #expect(german.contains("22:13"))
    }
}

@Suite struct ComposerTests {
    @Test func sendingNeedsAWritablePhaseAndSomethingToSend() {
        #expect(GiovComposerRules.canSend(phase: .ready, sending: false, busy: false, text: " hi ", fileCount: 0))
        #expect(GiovComposerRules.canSend(phase: .connecting, sending: false, busy: false, text: "", fileCount: 1))
        #expect(GiovComposerRules.canSend(phase: .active, sending: false, busy: false, text: "x", fileCount: 0))
        #expect(!GiovComposerRules.canSend(phase: .active, sending: false, busy: false, text: " \n ", fileCount: 0))
        #expect(!GiovComposerRules.canSend(phase: .active, sending: true, busy: false, text: "x", fileCount: 0))
        #expect(!GiovComposerRules.canSend(phase: .active, sending: false, busy: true, text: "x", fileCount: 0))
        #expect(!GiovComposerRules.canSend(phase: .preChat, sending: false, busy: false, text: "x", fileCount: 0))
        #expect(!GiovComposerRules.canSend(phase: .error, sending: false, busy: false, text: "x", fileCount: 0))
    }

    @Test func attachingNeedsAConversationAndAPolicyThatAllowsSomething() {
        #expect(!GiovComposerRules.canAttach(state(phase: .ready)))
        #expect(GiovComposerRules.canAttach(state(phase: .active, hasConversation: true)), "images by default")
        let off = GiovAttachmentPolicy(enabled: false, allowedTypes: ["image/png"], maxSizeMb: 5)
        #expect(!GiovComposerRules.canAttach(state(phase: .active, config: config(attachments: off), hasConversation: true)))
        let none = GiovAttachmentPolicy(enabled: true, allowedTypes: [], maxSizeMb: 5)
        #expect(!GiovComposerRules.canAttach(state(phase: .active, config: config(attachments: none), hasConversation: true)))
        #expect(GiovComposerRules.attachEnabled(sending: false, fileCount: 4))
        #expect(!GiovComposerRules.attachEnabled(sending: false, fileCount: 5))
        #expect(!GiovComposerRules.attachEnabled(sending: true, fileCount: 0))
    }

    @Test func messagesAreCutAtTheServerLimit() {
        let long = String(repeating: "a", count: 2100)
        #expect(GiovComposerRules.clamp(long).count == 2000)
        #expect(GiovComposerRules.clamp("short") == "short")
    }

    @Test func theLimitIsCountedInUTF16UnitsLikeTheServerWithoutSplittingACharacter() {
        // The server and the outbox count UTF-16 units (JavaScript's length); the composer used to count characters,
        // so 1500 emoji passed the composer and the send was then refused as over 2000.
        let emoji = String(repeating: "😀", count: 1500)
        let cut = GiovComposerRules.clamp(emoji)
        #expect(cut.utf16.count == 2000)
        #expect(cut.count == 1000)
        let odd = "a" + emoji
        #expect(GiovComposerRules.clamp(odd).utf16.count == 1999, "the emoji that would straddle the limit is left out whole")
        let flags = String(repeating: "🇫🇷", count: 600)
        #expect(GiovComposerRules.clamp(flags).count == 500, "a flag (four units) is never cut in half")
        let exact = String(repeating: "b", count: 2000)
        #expect(GiovComposerRules.clamp(exact) == exact)
    }

    @Test func thePickersFollowThePolicy() {
        let images = GiovPickerOptions(policy: .default, alreadyAttached: 0)
        #expect(images.photos)
        #expect(images.files)
        #expect(images.maxPhotos == 5)
        let documents = GiovPickerOptions(policy: GiovAttachmentPolicy(enabled: true, allowedTypes: ["application/pdf"], maxSizeMb: 5), alreadyAttached: 3)
        #expect(!documents.photos)
        #expect(documents.files)
        #expect(documents.maxPhotos == 2)
        #expect(documents.allowedTypes == ["application/pdf"])
        let off = GiovPickerOptions(policy: GiovAttachmentPolicy(enabled: false, allowedTypes: ["image/png"], maxSizeMb: 5), alreadyAttached: 5)
        #expect(!off.photos && !off.files)
        #expect(off.maxPhotos == 1)
    }

    @Test func chipsShowUploadProgressThenTheName() {
        let uploads = [GiovUploadProgress(name: "a.png", progress: 0.426)]
        #expect(giovChipText(index: 0, name: "a.png", uploads: uploads, strings: strings) == "Uploading 42%")
        #expect(giovChipText(index: 1, name: "b.pdf", uploads: uploads, strings: strings) == "b.pdf")
        #expect(giovChipText(index: 0, name: "a.png", uploads: [], strings: strings) == "a.png")
    }

    @Test func refusedPicksReadAsOneSentence() {
        #expect(giovProblemText([], strings: strings) == nil)
        let text = giovProblemText([.typeNotAllowed(name: "a.exe"), .tooLarge(name: "b.png", maxSizeMb: 5)], strings: strings)
        #expect(text == "a.exe: this file type is not allowed. b.png: files must be 5 MB or smaller.")
        #expect(giovProblemText([.tooMany(max: 5)], strings: strings) == "You can attach up to 5 files at a time.")
    }

    @Test func theListFollowsNewRowsGrowingRepliesAndTyping() {
        var value = state(phase: .active)
        let empty = GiovScrollSignature(value)
        value.messages = [message(content: "Hi")]
        let one = GiovScrollSignature(value)
        #expect(one != empty)
        value.messages = [message(content: "Hi there")]
        #expect(GiovScrollSignature(value) != one, "a streaming reply that grows")
        let grown = GiovScrollSignature(value)
        value.agentTyping = true
        let typing = GiovScrollSignature(value)
        #expect(typing != grown)
        value.unreadCount = 3
        value.connectionStatus = .connected
        #expect(GiovScrollSignature(value) == typing, "nothing new to show")
    }
}

@Suite struct AttachmentPresentationTests {
    private func box(_ preview: GiovAttachmentPreview?) -> [Double] {
        let size = giovPreviewBoxSize(preview)
        return [size.width, size.height]
    }

    @Test func imageBoxesKeepTheirShapeWithin200By150() {
        #expect(box(nil) == [200, 150])
        #expect(box(GiovAttachmentPreview(width: 4000, height: 3000)) == [200, 150])
        #expect(box(GiovAttachmentPreview(width: 1000, height: 2000)) == [75, 150])
        #expect(box(GiovAttachmentPreview(width: 100, height: 50)) == [100, 50])
        #expect(box(GiovAttachmentPreview(width: 4000, height: 1)) == [200, 1])
        #expect(box(GiovAttachmentPreview(width: 0, height: 10)) == [200, 150])
    }

    @Test func namesFallBackToTheURLThenToAGenericWord() {
        #expect(giovAttachmentName(GiovAttachment(url: "https://x.test/a/report.pdf", filename: "Q3.pdf"), strings: strings) == "Q3.pdf")
        #expect(giovAttachmentName(GiovAttachment(url: "https://x.test/a/report.pdf"), strings: strings) == "report.pdf")
        #expect(giovAttachmentName(GiovAttachment(url: "https://x.test/", contentType: "image/png"), strings: strings) == strings.image)
        #expect(giovAttachmentName(GiovAttachment(url: "https://x.test/"), strings: strings) == strings.attachment)
    }

    @Test func onlyHttpURLsAreOpenedOrDownloaded() {
        #expect(giovIsHTTPURL("https://x.test/a.png"))
        #expect(giovIsHTTPURL("HTTP://x.test/a.png"))
        #expect(!giovIsHTTPURL("javascript:alert(1)"))
        #expect(!giovIsHTTPURL("file:///a.png"))
        #expect(!giovIsHTTPURL("data:image/png;base64,AAAA"))
    }

    @Test func imageTypesAreSniffedFromTheBytes() {
        #expect(giovSniffImageType(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == "image/jpeg")
        #expect(giovSniffImageType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == "image/png")
        #expect(giovSniffImageType(Data("GIF89a....".utf8)) == "image/gif")
        #expect(giovSniffImageType(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == "image/webp")
        #expect(giovSniffImageType(Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])) == nil, "HEIC is re-encoded")
        #expect(giovSniffImageType(Data()) == nil)
    }

    @Test func fileTypesComeFromTheExtension() {
        #expect(giovMIMEType(forFileName: "Report.PDF") == "application/pdf")
        #expect(giovMIMEType(forFileName: "sheet.xlsx") == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        #expect(giovMIMEType(forFileName: "voice.m4a") == "audio/mp4")
        #expect(giovMIMEType(forFileName: "photo.jpeg") == "image/jpeg")
        #expect(giovMIMEType(forFileName: "noext") == "application/octet-stream")
        #expect(giovMIMEType(forFileName: ".hidden") == "application/octet-stream")
        #expect(giovMIMEType(forFileName: "tool.exe") == "application/octet-stream")
        for type in Set(GiovAttachmentLimits.supportedTypes) {
            #expect(["jpg", "png", "gif", "webp", "pdf", "txt", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "mp3", "m4a", "ogg", "weba", "wav"]
                .contains { giovMIMEType(forFileName: "f.\($0)") == type }, "every supported type has an extension: \(type)")
        }
    }

    @Test func libraryPhotosGetNames() {
        #expect(giovPhotoFileName(index: 0, mimeType: "image/jpeg") == "photo-1.jpg")
        #expect(giovPhotoFileName(index: 2, mimeType: "image/png") == "photo-3.png")
        #expect(giovPhotoFileName(index: 0, mimeType: "image/webp") == "photo-1.webp")
        #expect(giovPhotoFileName(index: 0, mimeType: "image/gif") == "photo-1.gif")
    }
}

@Suite struct PreChatTests {
    @Test func onlyRequiredFieldsAreCheckedAndEmailsMustLookRight() {
        let all = GiovRequestUserInfo(email: true, phone: true, firstName: true, lastName: true)
        #expect(!GiovPreChatValues().isValid(for: all))
        #expect(GiovPreChatValues().isValid(for: GiovRequestUserInfo()))
        #expect(GiovPreChatValues(firstName: "Ada", lastName: "L", email: "ada@example.com", phone: "+1 555").isValid(for: all))
        #expect(!GiovPreChatValues(firstName: "Ada", lastName: "L", email: "ada@example", phone: "+1").isValid(for: all))
        #expect(!GiovPreChatValues(firstName: "  ", lastName: "L", email: "ada@example.com", phone: "+1").isValid(for: all))
        #expect(GiovPreChatValues(email: " ada@example.com ").isValid(for: GiovRequestUserInfo(email: true)))
    }

    @Test func emailShapeMatchesTheWidget() {
        #expect(giovLooksLikeEmail("a@b.co"))
        #expect(giovLooksLikeEmail("first.last+tag@sub.example.org"))
        #expect(!giovLooksLikeEmail("a@b."))
        #expect(!giovLooksLikeEmail("a@.b"))
        #expect(!giovLooksLikeEmail("@b.co"))
        #expect(!giovLooksLikeEmail("a b@c.de"))
        #expect(!giovLooksLikeEmail("a@b@c.de"))
        #expect(!giovLooksLikeEmail("plain"))
    }

    @Test func theFormIsPrefilledAndSubmitsTrimmedValuesWithoutBlanks() {
        let values = GiovPreChatValues(contact: GiovContact(userId: "u1", email: "ada@example.com", firstName: "Ada"))
        #expect(values.firstName == "Ada")
        #expect(values.email == "ada@example.com")
        #expect(values.phone == "")
        var edited = values
        edited.lastName = "  Lovelace "
        #expect(edited.contact == GiovContact(email: "ada@example.com", firstName: "Ada", lastName: "Lovelace"))
    }
}
