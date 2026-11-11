import Foundation
@testable import GiovChatCore
import Testing

private func config(botEnabled: Bool = true, botName: String? = "Atlas") -> GiovWidgetConfig {
    GiovWidgetConfig(
        title: "Acme support",
        botEnabled: botEnabled,
        botName: botName,
        botAvatarURL: "https://cdn.test/atlas.png",
        avatarURL: "https://cdn.test/team.png"
    )
}

private func message(role: GiovRole = .agent, isBot: Bool = false, isAutomated: Bool = false, senderName: String? = nil) -> GiovMessage {
    GiovMessage(id: "m", role: role, content: "x", createdAt: 1, isBot: isBot, isAutomated: isAutomated, senderName: senderName)
}

@Suite struct IdentityTests {
    @Test func theHeaderIsThePersonOnceOneTakesOverElseTheBotWhileItAnswersElseTheTeam() {
        #expect(giovHeaderIdentity(config(), agentName: "Ada", agentAvatar: "https://cdn.test/ada.png") == GiovHeaderIdentity(kind: .person, title: "Ada", avatar: "https://cdn.test/ada.png"))
        #expect(giovHeaderIdentity(config()) == GiovHeaderIdentity(kind: .bot, title: "Atlas", avatar: "https://cdn.test/atlas.png"))
        #expect(giovHeaderIdentity(config(botEnabled: false)) == GiovHeaderIdentity(kind: .team, title: "Acme support", avatar: "https://cdn.test/team.png"))
        #expect(giovHeaderIdentity(config(botName: nil)).kind == .team)
        #expect(giovHeaderIdentity(config(), agentName: "Ada", agentAvatar: "javascript:alert(1)").avatar == nil, "only http(s) images load")
        #expect(giovHeaderIdentity(config(), agentName: "Ada").avatar == nil)
        #expect(giovHeaderIdentity(config(), agentName: "").kind == .bot, "an empty name is no person")
    }

    @Test func statusLinesComeFromTheStrings() {
        let strings = GiovChatStrings.en
        #expect(giovHeaderIdentity(config(), agentName: "Ada").status(strings) == "Live agent")
        #expect(giovHeaderIdentity(config()).status(strings) == "AI assistant · Online")
        #expect(giovHeaderIdentity(config(botEnabled: false)).status(strings) == "We'll be with you shortly")
    }

    @Test func senderLabelsAiIdentityWinsOverAutomatedPeopleByNameVisitorsAsYou() {
        let strings = GiovChatStrings.en
        #expect(giovMessageSenderLabel(message(isBot: true, isAutomated: true), strings: strings, botName: "Atlas") == "Atlas")
        #expect(giovMessageSenderLabel(message(isBot: true), strings: strings, botName: " ") == "GiovBot")
        #expect(giovMessageSenderLabel(message(isAutomated: true, senderName: "x"), strings: strings) == "Automated")
        #expect(giovMessageSenderLabel(message(senderName: " Ada "), strings: strings) == "Ada")
        #expect(giovMessageSenderLabel(message(), strings: strings, agentName: "Bola") == "Bola")
        #expect(giovMessageSenderLabel(message(), strings: strings) == "Agent")
        #expect(giovMessageSenderLabel(message(role: .visitor, isBot: true), strings: strings) == "You")
    }

    @Test func onlyExplicitServerAiMetadataBrandsTypingAMismatchedEndKeepsTheOtherIndicator() {
        var state = GiovTypingState()
        state = reduceAgentTyping(state, frame: json(["type": "typing", "role": "agent", "isBot": true]))
        #expect(state == GiovTypingState(visible: true, isBot: true))
        #expect(reduceAgentTyping(state, frame: json(["type": "typing_end", "role": "agent", "isBot": false])) == state)
        #expect(reduceAgentTyping(state, frame: json(["type": "typing_end", "role": "agent"])) == GiovTypingState())
        #expect(reduceAgentTyping(state, frame: json(["type": "typing", "role": "visitor"])) == state)
        #expect(reduceAgentTyping(GiovTypingState(), frame: json(["type": "typing", "role": "agent", "isBot": "true"])) == GiovTypingState(visible: true))
    }
}

@Suite struct I18nTests {
    @Test func everyShippedLanguageBuildsEveryStringAndNoneIsEmpty() {
        #expect(Set(giovLocales) == Set(GiovChatStrings.all.keys))
        for (code, s) in GiovChatStrings.all {
            let plain = [
                s.loading, s.tryAgain, s.retry, s.closeChat, s.connecting, s.reconnecting, s.statusPerson, s.statusBot, s.statusTeam,
                s.composerPlaceholder, s.messageInput, s.sendMessage, s.attachFile, s.you, s.agent, s.automated, s.teamTyping,
                s.sending, s.notSent, s.tapToRetry, s.discard, s.uploadFailed, s.sessionExpired, s.conversationEnded, s.unavailable,
                s.sendFailed, s.busy, s.attachmentsOff, s.attachment, s.image, s.preChatTitle, s.firstName, s.lastName, s.email,
                s.phone, s.startChat, s.privacyPolicy, s.moreOptions, s.removeAttachment("f.png"), s.botTyping("Atlas"), s.uploading(42),
                s.typeNotAllowed("a.pdf"), s.fileTooLarge("a.pdf", 5), s.tooManyFiles(5), s.openAttachment("a.pdf"), s.required("Email"),
            ]
            for text in plain { #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(code)") }
            #expect(s.botTyping("Atlas").contains("Atlas"), "\(code)")
            #expect(s.uploading(42).contains("42"), "\(code)")
            #expect(s.fileTooLarge("a.pdf", 5).contains("a.pdf") && s.fileTooLarge("a.pdf", 5).contains("5"), "\(code)")
            #expect(s.fileTooLarge("a.pdf", 2.5).contains("2.5"), "\(code)")
            #expect(!s.fileTooLarge("a.pdf", 5).contains("5.0"), "a whole number has no decimals")
            #expect(s.tooManyFiles(5).contains("5"), "\(code)")
        }
        #expect(GiovChatStrings.fr.typeNotAllowed("a.pdf") == "a.pdf : ce type de fichier n'est pas autorisé.")
        #expect(GiovChatStrings.de.uploading(42) == "Wird hochgeladen: 42 %")
        #expect(GiovChatStrings.en.statusBot == "AI assistant · Online")
        #expect(GiovChatStrings.en.discard == "Discard")
        #expect(GiovChatStrings.fr.discard == "Supprimer")
        #expect(GiovChatStrings.es.discard == "Descartar")
        #expect(GiovChatStrings.pt.discard == "Descartar")
        #expect(GiovChatStrings.de.discard == "Verwerfen")
    }

    @Test func localeResolution() {
        #expect(giovResolveLocale("fr-CA") == "fr")
        #expect(giovResolveLocale("pt_BR") == "pt")
        #expect(giovResolveLocale("DE") == "de")
        #expect(giovResolveLocale("ja-JP") == "en")
        #expect(giovResolveLocale(nil) == "en")
        #expect(giovResolveLocale("") == "en")
        #expect(giovResolveStrings("es").you == "Tú")
        #expect(!giovResolveStrings().loading.isEmpty, "device locale falls back to a shipped language")
    }

    @Test func hostOverridesReplaceStringsBlankOnesAreIgnored() {
        let strings = giovResolveStrings("es") { base in
            base.withOverrides(tryAgain: "", sendMessage: "Mandar", botTyping: { "\($0)…" })
        }
        #expect(strings.sendMessage == "Mandar")
        #expect(strings.tryAgain == GiovChatStrings.es.tryAgain)
        #expect(strings.botTyping("Atlas") == "Atlas…")
        #expect(strings.you == GiovChatStrings.es.you)
    }

    @Test func failuresMapToSentencesNeverServerText() {
        let strings = GiovChatStrings.en
        #expect(strings.describeError(GiovChatError.sessionExpired("x")) == strings.sessionExpired)
        #expect(strings.describeError(GiovChatError.conversationClosed("x")) == strings.conversationEnded)
        #expect(strings.describeError(GiovChatError.workspaceBusy("x", retryAfterSeconds: 30)) == strings.busy)
        #expect(strings.describeError(GiovChatError.attachmentRejected("x")) == strings.uploadFailed)
        #expect(strings.describeError(GiovChatError.sendFailed("x")) == strings.sendFailed)
        #expect(strings.describeError(GiovChatError.network("boom")) == strings.unavailable)
        #expect(strings.describeError(GiovChatError.server("boom", status: 500)) != "boom")
        #expect(strings.describeError(CancellationError()) == strings.unavailable)
    }

    @Test func attachmentProblemsBecomeSentences() {
        let strings = GiovChatStrings.en
        #expect(strings.describeProblem(.disabled) == strings.attachmentsOff)
        #expect(strings.describeProblem(.typeNotAllowed(name: "a.exe")) == "a.exe: this file type is not allowed.")
        #expect(strings.describeProblem(.tooLarge(name: "a.pdf", maxSizeMb: 2)) == "a.pdf: files must be 2 MB or smaller.")
        #expect(strings.describeProblem(.tooMany(max: 5)) == "You can attach up to 5 files at a time.")
    }
}

@Suite struct SessionScopeTests {
    @Test func scopeDiffersPerWorkspaceAndVisitorIdentity() {
        let a = giovSessionScope(baseURL: "https://api.test/", tenantKey: "t", contact: GiovContact(userId: "u1"))
        #expect(a == giovSessionScope(baseURL: "https://api.test", tenantKey: "t", contact: GiovContact(userId: "u1")))
        #expect(a == #"["https://api.test","t",null,"u1"]"#)
        #expect(a != giovSessionScope(baseURL: "https://api.test", tenantKey: "t", contact: GiovContact(userId: "u2")))
        #expect(a != giovSessionScope(baseURL: "https://api.test", tenantKey: "other", contact: GiovContact(userId: "u1")))
        #expect(a != giovSessionScope(baseURL: "https://api.test", tenantKey: "t", contact: GiovContact(userId: "u1"), sessionKey: "acct-2"))
    }

    @Test func contactStartFieldsCarryUserIdAndHashAndSkipEmptyValues() {
        #expect(GiovContact(userId: "u1", userHash: "ab", email: " ", firstName: " Ada ").startFields == ["userId": "u1", "userHash": "ab", "firstName": "Ada"])
        #expect(GiovContact(email: "a@b.co").merging(GiovContact(firstName: "Ada")) == GiovContact(email: "a@b.co", firstName: "Ada"))
    }

    @Test func onlyWellFormedStoredSessionsAreUsed() {
        #expect(isValidStoredSession(testSession))
        #expect(!isValidStoredSession(GiovSession(conversationId: "c", sessionToken: "short")))
        #expect(!isValidStoredSession(GiovSession(conversationId: "", sessionToken: String(repeating: "b", count: 64))))
        #expect(!isValidStoredSession(GiovSession(conversationId: "c", sessionToken: String(repeating: "B", count: 64))))
        #expect(!isValidStoredSession(GiovSession(conversationId: "c", sessionToken: String(repeating: "b", count: 64) + "\n")))
        #expect(!isValidStoredSession(nil))
    }

    @Test func theSessionTokenNeverAppearsInDescriptions() {
        #expect(!String(describing: testSession).contains("bbbb"))
        #expect(!String(reflecting: testSession).contains("bbbb"))
    }

    @Test func inMemoryStoreKeepsOneSessionPerScope() async throws {
        let store = InMemoryGiovSessionStore()
        try await store.write(scope: "a", session: testSession)
        #expect(try await store.read(scope: "a") == testSession)
        #expect(try await store.read(scope: "b") == nil)
        try await store.delete(scope: "a")
        #expect(try await store.read(scope: "a") == nil)
    }

    @Test func baseURLsAreValidated() throws {
        #expect(try normalizeBaseURL("https://api.example.test/") == "https://api.example.test")
        #expect(try normalizeBaseURL("http://127.0.0.1:8787") == "http://127.0.0.1:8787")
        for bad in ["ftp://x.test", "https://u:p@x.test", "https://x.test?a=1", "not a url", "https://x.test#f", ""] {
            #expect(throws: GiovInvalidBaseURL.self, "\(bad)") { try normalizeBaseURL(bad) }
        }
    }

    @Test func componentsAreEncodedLikeTheOtherSdks() {
        #expect(encodeComponent("a b+c/d?é") == "a%20b%2Bc%2Fd%3F%C3%A9")
        #expect(encodeComponent("A-z_0.9*") == "A-z_0.9*")
    }
}
