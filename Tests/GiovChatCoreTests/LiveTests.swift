import Foundation
@testable import GiovChatCore
import Testing

// Opt-in: drives real controllers through the production URLSession transports against a running Giov API.
//
//   GIOV_LIVE_BASE=http://host.docker.internal:8787 GIOV_LIVE_TENANT=<workspace key> \
//     swift test --filter LiveTests
//
// Skipped unless both variables are set. Each run starts one new conversation in that workspace.

enum LiveEnvironment {
    static var base: String? { value("GIOV_LIVE_BASE") }
    static var tenant: String? { value("GIOV_LIVE_TENANT") }
    static var configured: Bool { base != nil && tenant != nil }

    private static func value(_ name: String) -> String? {
        guard let text = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

@MainActor
private final class ErrorLog {
    var errors: [GiovChatError] = []
}

@MainActor
@Suite(.serialized, .enabled(if: LiveEnvironment.configured, "set GIOV_LIVE_BASE and GIOV_LIVE_TENANT to run against a real API"))
struct LiveTests {
    private func controller(_ store: any GiovSessionStore, log: ErrorLog) -> GiovChatController {
        GiovChatController(
            tenantKey: LiveEnvironment.tenant ?? "",
            baseURL: LiveEnvironment.base ?? giovDefaultBaseURL,
            // Every pre-chat field a workspace may ask for, so the first message starts the conversation.
            contact: GiovContact(email: "ios-live-test@example.com", phone: "+15555550100", firstName: "iOS", lastName: "Live test"),
            sessionStore: store,
            locale: "en",
            onError: { log.errors.append($0) },
            http: URLSessionGiovHTTP(),
            socketFactory: URLSessionGiovSocketFactory(),
            clock: GiovSystemClock()
        )
    }

    @Test(.timeLimit(.minutes(2)))
    func startSendAcknowledgeCloseThenResumeWithHistory() async throws {
        let store = InMemoryGiovSessionStore()
        let log = ErrorLog()
        let text = "iOS live test \(UUID().uuidString.prefix(8))"

        let first = controller(store, log: log)
        await first.start()
        #expect(first.state.config != nil, "config loaded; errors: \(log.errors)")
        #expect(first.state.phase == .ready, "opening the chat creates nothing")
        #expect(first.state.conversationId == nil)

        #expect(await first.send(text))
        #expect(await eventually(30) { first.state.conversationId != nil }, "conversation started; errors: \(log.errors)")
        #expect(await eventually(30) { first.state.isConnected }, "socket connected; errors: \(log.errors)")
        #expect(await eventually(30) {
            first.state.messages.contains { $0.content == text && $0.delivery == .sent && $0.id != $0.clientMessageId }
        }, "message acknowledged with a server id; errors: \(log.errors)")
        let conversationId = try #require(first.state.conversationId)
        let sent = try #require(first.state.messages.first { $0.content == text })
        #expect(first.state.phase == .active)
        first.close()
        let stored = try await store.read(scope: giovSessionScope(
            baseURL: LiveEnvironment.base ?? "",
            tenantKey: LiveEnvironment.tenant ?? "",
            contact: GiovContact(email: "ios-live-test@example.com", phone: "+15555550100", firstName: "iOS", lastName: "Live test")
        ))
        #expect(stored?.conversationId == conversationId, "the session was stored")

        let second = controller(store, log: log)
        await second.start()
        #expect(await eventually(30) { second.state.phase == .active && second.state.isConnected }, "resumed; errors: \(log.errors)")
        #expect(second.state.conversationId == conversationId)
        #expect(await eventually(30) { second.state.messages.contains { $0.id == sent.id && $0.content == text } }, "the message is in the history")
        second.close()
        #expect(log.errors.isEmpty, "no errors: \(log.errors)")
    }
}
