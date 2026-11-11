import Foundation
@testable import GiovChatCore
import Testing

// Behaviour every Giov SDK shares (round 2 of the pre-publish review; see each test).

private let apnsToken = String(repeating: "ab", count: 32)

@MainActor
@Suite struct ParityTests {
    // MARK: - Catch-up after a reconnect

    @Test func aFailedHistoryReloadAfterAReconnectStillSendsTheOutboxOnTheNewSocket() async {
        // The outbox used to wait for a history load that had failed, until some later reconnect.
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.drop()
        #expect(rig.ui.reconnecting, "a socket that was open is being restored")
        #expect(await rig.controller.send("typed while offline"))
        rig.server.historyStatuses = [500]
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 2)
        await rig.open()
        #expect(rig.socket.messageFrames().contains { $0["content"].string == "typed while offline" })
        #expect(rig.phase == .active)
        #expect(!rig.ui.reconnecting)
        #expect(rig.ui.error?.kind == .server)
        await rig.dispose()
    }

    @Test func aDeadSessionFoundByTheCatchUpEndsTheChatAndForgetsTheStoredPair() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.drop()
        // 401, a renewed token, 401 again: the session is gone.
        rig.server.historyStatuses = [401, 401]
        await rig.elapse(1_500)
        await rig.open()
        #expect(rig.phase == .error)
        #expect(rig.ui.error?.kind == .sessionExpired)
        #expect(rig.store.log.contains("delete"))
        #expect(!rig.ui.hasConversation)
        #expect(rig.socket.closedByClient)
        #expect(!rig.ui.reconnecting)
        await rig.elapse(60_000)
        #expect(rig.sockets.all.count == 2, "no further reconnects")
        await rig.dispose()
    }

    // MARK: - Uploads

    @Test func theWholeUploadExchangeIsBoundedByTheUploadTimeout() async {
        // A token renewal and a second upload used to let one file take twice the upload timeout, or longer.
        let rig = ClientRig()
        await rig.connect()
        rig.server.uploadDelayMs = 100_000
        rig.server.uploadStatuses = [401]
        let file = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 4))
        let upload = rig.startThrowing { try await rig.client.uploadAttachment(file) }
        await rig.elapse(120_000)
        #expect(upload.result != nil, "finished at the timeout")
        #expect(upload.error?.kind == .network)
        #expect(upload.error?.timedOut == true)
        rig.client.dispose()
    }

    // MARK: - Push

    @Test func pushRegistrationCarriesTheChatsLocale() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        #expect(await rig.controller.registerPushToken(apnsToken, appId: "com.acme.app").registered)
        let request = try #require(rig.server.to("/conversations/conv-1/push-token", "POST").last)
        #expect(request.json["locale"] == .string("en"))
        await rig.dispose()
    }

    @Test func theLastTokenIsRegisteredAgainForANewConversationAndResetForgetsIt() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        #expect(await rig.controller.registerPushToken(apnsToken, appId: "com.acme.app").registered)
        #expect(rig.server.count("push-POST") == 1)

        // The team deletes the conversation; the visitor's next message starts a new one.
        await rig.drop(code: 1000, reason: "Conversation deleted")
        #expect(!rig.ui.hasConversation)
        #expect(await rig.controller.send("Back again"))
        await rig.pump()
        await rig.open()
        #expect(rig.server.count("created") == 2)
        #expect(rig.server.count("push-POST") == 2, "registered again without the host asking")
        #expect(rig.server.to("/conversations/conv-1/push-token", "POST").last?.json["token"] == .string(apnsToken))

        await rig.controller.reset()
        await rig.pump()
        #expect(await rig.controller.send("Someone else"))
        await rig.pump()
        await rig.open()
        #expect(rig.server.count("created") == 3)
        #expect(rig.server.count("push-POST") == 2, "a reset (sign-out) forgets the token")
        await rig.dispose()
    }

    @Test func aRegistrationBeforeAnyConversationWaitsForTheFirstOneOrEndsWithNoConversation() async {
        let rig = CRig()
        await rig.start()
        let waiting = rig.start { await rig.controller.registerPushToken(apnsToken) }
        await rig.pump()
        #expect(!waiting.isCompleted)
        #expect(await rig.controller.send("Hi"))
        await rig.pump()
        await rig.open()
        #expect(waiting.value?.registered == true)

        let other = CRig()
        await other.start()
        let abandoned = other.start { await other.controller.registerPushToken(apnsToken) }
        await other.pump()
        other.controller.close()
        await other.pump()
        #expect(abandoned.value == .notRegistered(.noConversation))

        let signedOut = CRig()
        await signedOut.start()
        let cleared = signedOut.start { await signedOut.controller.registerPushToken(apnsToken) }
        await signedOut.pump()
        await signedOut.controller.reset()
        await signedOut.pump()
        #expect(cleared.value == .notRegistered(.noConversation))
        await rig.dispose()
        await signedOut.dispose()
    }

    @Test func unregisteringWorksWithoutAConnectionThroughTheStoredSession() async throws {
        // It used to need a connected socket, so a sign-out while the chat was closed left the device registered.
        let rig = CRig(visible: false, stored: testSession)
        await rig.start()
        #expect(rig.sockets.all.isEmpty)
        #expect(await rig.controller.unregisterPushToken(apnsToken))
        let request = try #require(rig.server.to("/conversations/conv-1/push-token", "DELETE").first)
        #expect(request.headers["Authorization"] == "Bearer visitor-token-1")
        #expect(request.json == json(["token": apnsToken]))
        await rig.dispose()
    }

    // MARK: - start()

    @Test func startingAStartedControllerAgainChangesNothing() async {
        // GiovChatView calls start() when it appears; for a shared keepConnected controller that used to drop the
        // socket and a reply being written every time the sheet opened.
        let rig = CRig(stored: testSession)
        await rig.start()
        await rig.open()
        await rig.receive(["type": "stream", "streamId": "s1", "content": "Hel"])
        #expect(rig.ui.messages.contains { $0.isStreaming })
        let again = rig.start { await rig.controller.start() }
        await rig.pump()
        #expect(again.isCompleted)
        #expect(rig.sockets.all.count == 1)
        #expect(!rig.socket.closedByClient)
        #expect(rig.ui.messages.contains { $0.isStreaming }, "the draft is kept")
        #expect(rig.phase == .active)
        _ = rig.start { await rig.controller.retry() }
        await rig.pump()
        #expect(rig.sockets.all.count == 2, "retry() is still the explicit restart")
        await rig.dispose()
    }

    // MARK: - Session scope

    @Test func theStorageScopeIsTheWorkspaceSessionKeyAndUserIdOnly() {
        let base = giovSessionScope(baseURL: "https://api.test", tenantKey: "t", contact: GiovContact(userId: "u1"))
        let edited = giovSessionScope(
            baseURL: "https://api.test",
            tenantKey: "t",
            contact: GiovContact(userId: "u1", email: "ada@acme.test", phone: "+1", firstName: "Ada", lastName: "L")
        )
        #expect(base == edited, "filling in the pre-chat form or editing a name keeps the conversation")
        #expect(giovSessionScope(baseURL: "https://api.test", tenantKey: "t", contact: GiovContact(email: "a@b.co"))
            == giovSessionScope(baseURL: "https://api.test", tenantKey: "t"))
    }

    // MARK: - First connection

    @Test func aFirstConnectionThatFailsIsRetriedWithBackoffShowingReconnecting() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        rig.socket.fail(nil, message: "offline")
        await rig.pump()
        #expect(rig.phase == .connecting, "not the error screen")
        #expect(rig.ui.reconnecting)
        #expect(rig.errors.last?.kind == .network)
        #expect(rig.sockets.all.count == 1)
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 2, "tried again after the protocol's first backoff")
        rig.socket.fail(nil, message: "still offline")
        await rig.pump()
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 2, "the second wait is longer")
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 3)
        await rig.open()
        #expect(rig.phase == .active)
        #expect(!rig.ui.reconnecting)
        #expect(rig.store.log.isEmpty, "the conversation is kept")
        await rig.dispose()
    }

    @Test func aClosedConversationClearsTheTranscriptLikeTheWebWidget() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.receive(["id": "a1", "role": "agent", "content": "Bye", "createdAt": 10, "senderName": "Ada"])
        #expect(!rig.ui.messages.isEmpty)
        await rig.drop(code: 1000, reason: "Conversation deleted")
        // The web widget drops the closed conversation's messages and keeps only what is still unsent (its outbox),
        // which goes to the next conversation.
        #expect(!rig.ui.messages.contains { $0.id == "a1" })
        #expect(rig.ui.messages.allSatisfy { $0.role == .visitor && $0.delivery != .sent })
        #expect(rig.ui.error?.kind == .conversationClosed)
        await rig.dispose()
    }
}
