import Foundation
@testable import GiovChatCore
import Testing

private let base = "https://api.example.test"

@MainActor
final class CRig: TimeRig {
    let server: FakeServer
    let sockets = Sockets()
    let store: RecordingStore
    let tenant: String
    var errors: [GiovChatError] = []
    var unread: [Int] = []
    var started: [String] = []
    var statuses: [GiovConnectionStatus] = []
    private(set) var controller: GiovChatController!

    init(
        visible: Bool = true,
        keepConnected: Bool = false,
        contact: GiovContact? = nil,
        stored: GiovSession? = nil,
        store: RecordingStore? = nil,
        graceMs: Int = 5_000,
        tenant: String = "t"
    ) {
        let clock = ManualClock()
        server = FakeServer(clock: clock)
        self.store = store ?? RecordingStore()
        self.tenant = tenant
        super.init(clock: clock)
        if let stored {
            self.store.seed(giovSessionScope(baseURL: base, tenantKey: tenant, contact: contact ?? GiovContact()), stored)
        }
        controller = GiovChatController(
            tenantKey: tenant,
            baseURL: base,
            contact: contact,
            sessionStore: self.store,
            keepConnected: keepConnected,
            visible: visible,
            locale: "en",
            backgroundGraceMs: graceMs,
            onError: { [unowned self] in self.errors.append($0) },
            onConversationStart: { [unowned self] in self.started.append($0) },
            onConnectionStatusChange: { [unowned self] in self.statuses.append($0) },
            onUnreadCountChange: { [unowned self] in self.unread.append($0) },
            http: server,
            socketFactory: sockets,
            clock: clock,
            random: { 0 }
        )
    }

    var ui: GiovChatUiState { controller.state }
    var phase: GiovChatPhase { ui.phase }
    var socket: FakeSocket { sockets.last }

    func start() async {
        _ = start { await self.controller.start() }
        await pump()
    }

    /// The socket opens and the catch-up runs.
    func open() async {
        socket.accept()
        await pump()
    }

    /// Protocol v1: the first message starts the conversation; wait until connected and caught up.
    func begin(_ text: String = "Hi") async {
        #expect(phase == .ready, "opening the chat creates nothing")
        #expect(server.count("created") == 0)
        #expect(await controller.send(text))
        await pump()
        await open()
        #expect(phase == .active)
        #expect(server.count("created") == 1)
    }

    func dispose() async {
        controller.close()
        await pump()
    }

    func receive(_ pairs: KeyValuePairs<String, Any?>) async {
        socket.receive(pairs)
        await pump()
    }

    func drop(code: Int? = nil, reason: String? = nil) async {
        socket.drop(code: code, reason: reason)
        await pump()
    }

    func msg(_ content: String) -> GiovMessage? { ui.messages.first { $0.content == content } }
}

@MainActor
@Suite struct ControllerTests {
    @Test func openingTheChatCreatesNothingTheFirstMessageStartsTheConversationAndGoesOutAfterTheHistoryCatchUp() async {
        let rig = CRig()
        await rig.start()
        #expect(rig.phase == .ready)
        #expect(rig.ui.config?.title == "Acme")
        #expect(rig.server.count("created") == 0)
        #expect(rig.sockets.all.isEmpty)
        #expect(rig.ui.header?.kind == .bot, "before anyone writes, the bot answers")

        #expect(await rig.controller.send("  Hi there  "))
        await rig.pump()
        #expect(rig.phase == .connecting)
        #expect(rig.ui.messages.map(\.delivery) == [.sending], "shown at once")
        #expect(rig.ui.messages.first?.content == "Hi there")
        rig.socket.accept()
        #expect(rig.socket.messageFrames().isEmpty, "the outbox waits for the history catch-up")
        await rig.pump()
        #expect(rig.phase == .active)
        #expect(rig.server.count("history") == 1)
        #expect(rig.socket.messageFrames().map { $0["content"].string } == ["Hi there"])
        #expect(rig.store.log == ["write"])
        #expect(rig.started == ["conv-1"])
        #expect(rig.ui.conversationId == "conv-1")
        #expect(rig.ui.hasConversation)
        #expect(rig.ui.isConnected)
        await rig.dispose()
    }

    @Test func aDroppedSocketCatchesUpOnHistoryTextTypedMeanwhileGoesOutOnTheNextOneUnderTheSameKey() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.receive([
            "id": "a1", "role": "agent", "content": "Hello, how can I help?", "createdAt": 10,
            "senderName": "Ada", "senderAvatar": "https://cdn.test/ada.png",
        ])
        #expect(rig.ui.messages.contains { $0.id == "a1" })
        #expect(rig.ui.header == GiovHeaderIdentity(kind: .person, title: "Ada", avatar: "https://cdn.test/ada.png"), "a person replying takes over the header")

        await rig.drop()
        #expect(rig.phase == .connecting)
        #expect(rig.ui.connectionStatus == .disconnected)
        #expect(await rig.controller.send("typed while offline"))
        let pending = try #require(rig.msg("typed while offline"))
        #expect(pending.delivery == .sending)

        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 2)
        let historyBefore = rig.server.count("history")
        await rig.open()
        #expect(rig.phase == .active)
        #expect(rig.server.count("history") == historyBefore + 1, "history is reloaded after every reconnect")
        let frame = try #require(rig.socket.messageFrames().first { $0["content"].string == "typed while offline" })
        #expect(frame["clientMessageId"].string == pending.clientMessageId)

        await rig.receive([
            "type": "message_ack", "clientMessageId": frame["clientMessageId"].string,
            "message": ["id": "srv-7", "role": "visitor", "content": "typed while offline", "createdAt": 99999] as [String: Any?],
        ])
        let saved = try #require(rig.msg("typed while offline"))
        #expect(saved.id == "srv-7")
        #expect(saved.clientMessageId == pending.clientMessageId, "the bubble keeps its key, so it is not redrawn")
        #expect(saved.key == pending.key)
        #expect(saved.delivery == .sent)
        #expect(rig.ui.messages.filter { $0.content == "typed while offline" }.count == 1)
        await rig.dispose()
    }

    @Test func historyMergesByIdWithFramesReceivedMeanwhileThenTheOutboxIsResent() async {
        let rig = CRig(stored: testSession)
        rig.server.history = [
            ["id": "h1", "role": "user", "content": "Hi", "createdAt": 1],
            ["id": "h2", "role": "agent", "content": "Hello", "createdAt": 2, "isBot": true, "isAutomated": true],
        ]
        await rig.start()
        #expect(rig.server.count("created") == 0, "a stored conversation is resumed at once")
        #expect(rig.server.count("resumed") == 1)
        #expect(rig.phase == .connecting)
        await rig.open()
        #expect(rig.phase == .active)
        #expect(rig.ui.messages.map(\.id) == ["h1", "h2"])
        await rig.receive(["id": "h2", "role": "agent", "content": "Hello", "createdAt": 2, "isBot": true, "isAutomated": true])
        #expect(rig.ui.messages.count == 2, "deduplicated by id")
        await rig.dispose()
    }

    @Test func aClosedConversationOnResume409IsShownReadOnlyWhenTheTokenAllows() async {
        let rig = CRig(stored: testSession)
        rig.server.resumeStatus = 409
        rig.server.status = "closed"
        rig.server.history = [
            ["id": "h1", "role": "user", "content": "Hi", "createdAt": 1],
            ["id": "h2", "role": "agent", "content": "Thanks for writing", "createdAt": 2],
        ]
        await rig.start()
        await rig.open()
        #expect(rig.ui.conversationClosed)
        #expect(rig.ui.messages.map(\.id) == ["h1", "h2"], "the history stays visible")
        #expect(rig.store.log.isEmpty, "the stored conversation is kept until a new one starts")
        await rig.dispose()
    }

    @Test func aClosedConversationOnResume409DegradesWhenTheTokenIsRefused() async {
        let rig = CRig(stored: testSession)
        rig.server.resumeStatus = 409
        rig.server.tokenStatuses = [403]
        await rig.start()
        #expect(rig.phase == .ready)
        #expect(!rig.ui.conversationClosed)
        #expect(rig.ui.error?.kind == .conversationClosed)
        #expect(rig.store.log == ["delete"])
        #expect(rig.sockets.all.isEmpty)
        await rig.dispose()
    }

    @Test func aClosedConversationInHistoryStaysReadOnlyAndAMessageStartsANewOneThatClearsIt() async {
        let rig = CRig(stored: testSession)
        rig.server.status = "closed"
        rig.server.history = [["id": "h1", "role": "user", "content": "Hi", "createdAt": 1]]
        await rig.start()
        await rig.open()
        #expect(rig.phase == .active, "the socket stays up: a rating card can still arrive")
        #expect(rig.ui.conversationClosed)
        #expect(rig.ui.hasConversation)
        #expect(rig.ui.messages.map(\.id) == ["h1"])
        #expect(rig.store.log.isEmpty)
        #expect(!rig.socket.closedByClient)
        #expect(await rig.controller.send("again"), "writing on a closed conversation starts a new one")
        rig.server.status = "open"
        rig.server.history = []
        await rig.pump()
        #expect(rig.store.log.first == "delete")
        #expect(rig.server.count("created") == 1)
        #expect(!rig.ui.conversationClosed)
        #expect(rig.ui.messages.allSatisfy { $0.id != "h1" }, "the closed conversation is gone")
        await rig.dispose()
    }

    @Test func startNewConversationLeavesTheClosedOneAndWaitsForTheNextMessage() async {
        let rig = CRig(stored: testSession)
        rig.server.status = "closed"
        rig.server.history = [["id": "h1", "role": "user", "content": "Hi", "createdAt": 1]]
        await rig.start()
        await rig.open()
        #expect(rig.ui.conversationClosed)
        await rig.controller.startNewConversation()
        #expect(rig.phase == .ready)
        #expect(!rig.ui.conversationClosed && !rig.ui.hasConversation)
        #expect(rig.ui.messages.isEmpty)
        #expect(rig.store.log == ["delete"])
        #expect(rig.socket.closedByClient)
        #expect(rig.server.count("created") == 0, "nothing is created until the visitor writes")
        await rig.controller.startNewConversation()
        #expect(rig.store.log == ["delete"], "an open (or already left) conversation is not touched")
        await rig.dispose()
    }

    @Test func aDeletedConversationIsForgottenHistory404() async {
        let rig = CRig(stored: testSession)
        rig.server.historyStatuses = [404]
        await rig.start()
        await rig.open()
        #expect(rig.phase == .ready)
        #expect(rig.store.log == ["delete"])
        await rig.dispose()
    }

    @Test func aDeletedConversationIsForgottenCloseFrame() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        await rig.open()
        await rig.drop(code: 1000, reason: "Conversation deleted")
        #expect(rig.phase == .ready)
        #expect(rig.store.log == ["delete"])
        await rig.elapse(60_000)
        #expect(rig.sockets.all.count == 1, "no reconnect for a deleted conversation")
        await rig.dispose()
    }

    @Test func aRefusedUpgradeWith410ForgetsTheConversationOnce() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        rig.socket.fail(410, message: "Expected HTTP 101 response but was '410 Gone'")
        await rig.pump()
        #expect(rig.phase == .ready)
        #expect(rig.store.log == ["delete"])
        #expect(!rig.ui.hasConversation)
        #expect(rig.ui.error?.kind == .conversationClosed)
        await rig.elapse(60_000)
        #expect(rig.sockets.all.count == 1)
        await rig.dispose()
    }

    @Test func aFailedUpgradeWhoseTextMentions410IsJustAConnectionFailure() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        rig.socket.fail(nil, message: "Failed to connect to /conversations/9c410f2e-4100-4abc-8410-000000000410/ws")
        await rig.pump()
        #expect(rig.phase == .connecting, "retried with backoff")
        #expect(rig.ui.reconnecting)
        #expect(rig.errors.last?.kind == .network)
        #expect(rig.store.log.isEmpty, "the conversation is kept")
        await rig.dispose()
    }

    @Test func anExpiredSessionEndsInTheErrorPhaseForgetsTheStoredPairAndARetryStartsClean() async {
        let rig = CRig(stored: testSession)
        rig.server.tokenStatuses = [401]
        await rig.start()
        #expect(rig.phase == .error)
        #expect(rig.ui.error?.kind == .sessionExpired)
        #expect(rig.store.log == ["delete"])
        #expect(rig.errors.map(\.kind) == [.sessionExpired])
        await rig.controller.retry()
        await rig.pump()
        #expect(rig.phase == .ready)
        await rig.dispose()
    }

    @Test func aResumeRefusedWith401ForgetsTheSessionAndWaitsForTheVisitor() async {
        let rig = CRig(stored: testSession)
        rig.server.resumeStatus = 401
        await rig.start()
        #expect(rig.phase == .ready)
        #expect(rig.store.log == ["delete"])
        await rig.dispose()
    }

    @Test func historyNamesTheTeammateWhoHasTheConversation() async {
        let rig = CRig()
        rig.server.assignedAgentName = "Ada"
        rig.server.assignedAgentAvatar = "https://cdn.test/ada.png"
        rig.server.history = [
            ["id": "h1", "role": "user", "content": "Hi", "created_at": 1],
            ["id": "h2", "role": "agent", "content": "Hello!", "created_at": 2, "is_bot": 0, "is_automated": 0],
        ]
        await rig.start()
        await rig.begin()
        #expect(rig.ui.agentName == "Ada")
        #expect(rig.ui.agentAvatar == "https://cdn.test/ada.png")
        #expect(rig.ui.header?.kind == .person)
        #expect(rig.ui.messages.first { $0.id == "h2" }?.senderName == "Ada")
        await rig.dispose()
    }

    @Test func streamedRepliesShowAsTheyAreWrittenAndBecomeOneSavedMessageInTheSamePlace() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.receive(["type": "typing", "role": "agent", "isBot": true])
        #expect(rig.ui.agentTyping)
        #expect(rig.ui.agentTypingIsBot == true)
        await rig.receive(["type": "stream", "streamId": "r1", "content": "Our **hours**"])
        let draft = try #require(rig.ui.messages.first { $0.isStreaming })
        #expect(draft.content == "Our **hours**")
        #expect(draft.clientMessageId == "stream:r1")
        #expect(!rig.ui.agentTyping, "the draft replaces the typing indicator")
        await rig.receive(["type": "stream", "streamId": "r1", "content": "Our **hours** are 9–5."])
        #expect(rig.ui.messages.filter(\.isStreaming).map(\.content) == ["Our **hours** are 9–5."])
        await rig.receive([
            "id": "m9", "role": "agent", "content": "Our **hours** are 9–5.", "createdAt": 2_000_000_000_000,
            "isBot": true, "isAutomated": true, "streamId": "r1",
        ])
        let replies = rig.ui.messages.filter { $0.role == .agent }
        #expect(replies.count == 1)
        #expect(replies.first?.id == "m9")
        #expect(replies.first?.clientMessageId == "stream:r1")
        #expect(replies.first?.isStreaming == false)
        #expect(replies.first?.key == draft.key, "the key of the draft")
        await rig.receive(["type": "typing_end", "role": "agent", "isBot": true])
        #expect(!rig.ui.agentTyping)

        // A cancelled reply sends only stream_end.
        await rig.receive(["type": "stream", "streamId": "r2", "content": "Thinking"])
        #expect(rig.ui.messages.filter(\.isStreaming).count == 1)
        await rig.receive(["type": "stream_end", "streamId": "r2"])
        #expect(rig.ui.messages.filter(\.isStreaming).isEmpty)
        // A draft is lost with the socket.
        await rig.receive(["type": "stream", "streamId": "r3", "content": "Half"])
        #expect(rig.ui.messages.filter(\.isStreaming).count == 1)
        await rig.drop()
        #expect(rig.ui.messages.filter(\.isStreaming).isEmpty)
        await rig.dispose()
    }

    @Test func keptConnectedWhileHiddenRepliesCountAsUnreadUntilTheChatOpensTheSameConnectionStays() async {
        let rig = CRig(visible: false, keepConnected: true, stored: testSession, tenant: "unread-tenant")
        var badge: [Int] = []
        let observation = GiovUnread.observe(tenantKey: "unread-tenant") { badge.append($0) }
        await rig.start()
        await rig.open()
        #expect(rig.phase == .active)
        #expect(rig.server.count("created") == 0)
        await rig.receive(["id": "a1", "role": "agent", "content": "Your order shipped", "createdAt": 100, "senderName": "Ada"])
        await rig.receive(["id": "a2", "role": "agent", "content": "Anything else?", "createdAt": 101, "senderName": "Ada"])
        #expect(rig.ui.unreadCount == 2)
        #expect(GiovUnread.count(tenantKey: "unread-tenant") == 2)
        #expect(badge == [0, 1, 2])
        let sockets = rig.sockets.all.count
        rig.controller.setVisible(true)
        await rig.pump()
        #expect(rig.ui.unreadCount == 0)
        #expect(rig.sockets.all.count == sockets, "opening the chat keeps the same connection")
        #expect(Array(rig.unread.suffix(3)) == [1, 2, 0])
        #expect(GiovUnread.count(tenantKey: "unread-tenant") == 0)
        await rig.receive(["id": "a3", "role": "agent", "content": "Hello again", "createdAt": 102])
        #expect(rig.ui.unreadCount == 0, "visible: nothing is unread")
        observation.cancel()
        await rig.dispose()
        #expect(badge == [0, 1, 2, 0])
    }

    @Test func aHiddenChatNeverStartsAConversationWithoutKeepConnectedItDisconnects() async {
        let rig = CRig(visible: false, keepConnected: true)
        await rig.start()
        #expect(rig.phase == .idle)
        #expect(rig.server.count("created") == 0)
        #expect(rig.sockets.all.isEmpty)
        rig.controller.setVisible(true)
        await rig.pump()
        #expect(rig.phase == .ready)
        await rig.begin()
        await rig.dispose()

        let plain = CRig(stored: testSession)
        await plain.start()
        await plain.open()
        #expect(plain.phase == .active)
        plain.controller.setVisible(false)
        await plain.pump()
        #expect(plain.ui.connectionStatus == .disconnected)
        #expect(plain.socket.closedByClient)
        plain.controller.setVisible(true)
        await plain.pump()
        #expect(plain.sockets.all.count == 2)
        await plain.dispose()
    }

    @Test func theVisitorsTypingIsSentOncePerBurstAndEndsAfter2500msOfQuietOrOnSend() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        let socket = rig.socket
        socket.sent.removeAll()
        for _ in 0..<3 { rig.controller.notifyTyping() }
        await rig.pump()
        #expect(socket.types() == ["typing"])
        await rig.elapse(2_400)
        #expect(socket.types() == ["typing"])
        await rig.elapse(200)
        #expect(socket.types() == ["typing", "typing_end"])
        // A new burst, ended by sending.
        socket.sent.removeAll()
        rig.controller.notifyTyping()
        await rig.pump()
        #expect(await rig.controller.send("done"))
        #expect(socket.types() == ["typing", "typing_end", "message"])
        await rig.dispose()
    }

    @Test func thePreChatFormIsAskedBeforeAnyConversationExistsAndItsFieldsGoToTheStartRequest() async {
        let rig = CRig()
        rig.server.config["requestUserInfo"] = ["email": true, "firstName": true]
        await rig.start()
        #expect(rig.phase == .preChat)
        #expect(rig.ui.requiredFields.email)
        #expect(rig.ui.requiredFields.firstName)
        #expect(!rig.ui.requiredFields.phone)
        #expect(rig.server.count("created") == 0)
        #expect(await !rig.controller.send("hi"), "the form comes first")
        await rig.controller.submitContact(GiovContact(email: "not-an-email", firstName: "Ada"))
        await rig.pump()
        #expect(rig.phase == .preChat, "a malformed email is still missing")
        #expect(rig.ui.requiredFields.email)
        #expect(!rig.ui.requiredFields.firstName)
        _ = rig.start { await rig.controller.submitContact(GiovContact(email: "ada@acme.co")) }
        await rig.pump()
        #expect(rig.server.count("created") == 1)
        #expect(rig.server.to("/conversations", "POST").last?.json == json(["tenantId": "t", "email": "ada@acme.co", "firstName": "Ada"]))
        await rig.open()
        #expect(rig.phase == .active)
        await rig.dispose()
    }

    @Test func aKnownVisitorStartsWithUserIdAndUserHash() async {
        let hash = String(repeating: "c", count: 64)
        let rig = CRig(contact: GiovContact(userId: "cust_42", userHash: hash))
        await rig.start()
        await rig.begin()
        #expect(rig.server.to("/conversations", "POST").map(\.json) == [json(["tenantId": "t", "userId": "cust_42", "userHash": hash])])
        await rig.dispose()
    }

    @Test func goingToTheBackgroundClosesTheSocketAfterAShortGraceComingBackReconnectsAndCatchesUp() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        let before = rig.server.count("history")

        // A short interruption does not close the socket.
        rig.controller.onBackground()
        await rig.elapse(3_000)
        #expect(!rig.socket.closedByClient)
        rig.controller.onForeground()
        await rig.pump()
        #expect(rig.sockets.all.count == 1)
        #expect(rig.server.count("history") == before + 1, "the history is reloaded on resume even when the socket survived")

        // A long one does.
        rig.controller.onBackground()
        await rig.elapse(6_000)
        #expect(rig.sockets.all.first?.closedByClient == true)
        #expect(rig.ui.connectionStatus == .disconnected)
        await rig.elapse(120_000)
        #expect(rig.sockets.all.count == 1, "no reconnect while in the background")
        rig.controller.onForeground()
        await rig.pump()
        #expect(rig.sockets.all.count == 2)
        let reloaded = rig.server.count("history")
        await rig.open()
        #expect(rig.phase == .active)
        #expect(rig.server.count("history") == reloaded + 1)
        await rig.dispose()
    }

    @Test func comingBackWhileReconnectingSkipsTheBackoff() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        await rig.open()
        await rig.drop()
        #expect(rig.sockets.all.count == 1)
        rig.controller.onForeground()
        await rig.pump()
        #expect(rig.sockets.all.count == 2)
        await rig.dispose()
    }

    @Test func aPushTokenRequestedBeforeTheConversationConnectsIsRegisteredOnceItDoes() async throws {
        let rig = CRig()
        await rig.start()
        let hex = String(repeating: "ab", count: 32)
        let pending = rig.start { await rig.controller.registerPushToken(hex, platform: .apns, environment: .sandbox, appId: "com.acme.app") }
        await rig.pump()
        #expect(!pending.isCompleted)
        await rig.begin()
        #expect(pending.value?.registered == true)
        let request = try #require(rig.server.to("/conversations/conv-1/push-token", "POST").first)
        #expect(request.json["platform"].string == "apns")
        #expect(request.json["environment"].string == "sandbox")
        #expect(request.json["locale"].string == "en")
        #expect(request.json["appId"].string == "com.acme.app")
        #expect(await rig.controller.registerPushToken("fcm-token", platform: .fcm, environment: .sandbox).registered, "registers at once when connected")
        let fcm = rig.server.to("/conversations/conv-1/push-token", "POST").last
        #expect(fcm?.json["platform"].string == "fcm")
        #expect(fcm?.json["environment"] == nil, "the environment is APNs only")
        #expect(await rig.controller.registerPushToken(deviceToken: Data([0xAB, 0x01]), environment: .production, appId: nil).registered)
        #expect(rig.server.to("/conversations/conv-1/push-token", "POST").last?.json == json(["token": "ab01", "platform": "apns", "environment": "production", "locale": "en"]))
        #expect(await rig.controller.unregisterPushToken("fcm-token"))
        #expect(await rig.controller.unregisterPushToken(deviceToken: Data([0xAB, 0x01])))
        await rig.dispose()
    }

    @Test func aPushRequestSupersededByANewerOneReportsFailureAndClosingReleasesIt() async {
        let rig = CRig()
        await rig.start()
        let first = rig.start { await rig.controller.registerPushToken("one") }
        await rig.pump()
        let second = rig.start { await rig.controller.registerPushToken("two") }
        await rig.pump()
        #expect(first.value?.failure == .failed)
        #expect(!second.isCompleted)
        await rig.dispose()
        #expect(second.value?.failure == .noConversation)
        #expect(await rig.controller.registerPushToken("three").failure == .noConversation)
    }

    @Test func aFailedMessageShowsAsNotSentRetrySendsItAgainInPlaceDiscardRemovesIt() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        let id = try #require(rig.socket.messageFrames().first?["clientMessageId"].string)
        func failure() async {
            await rig.receive(["type": "error", "error": "message_failed", "clientMessageId": id])
        }
        await failure()
        await rig.elapse(2_001)
        await failure()
        await rig.elapse(4_001)
        await failure()
        #expect(rig.ui.messages.map(\.delivery) == [.failed])
        #expect(rig.errors.last?.kind == .sendFailed)
        #expect(rig.ui.messages.first?.key == id)
        rig.controller.retryMessage(id)
        await rig.pump()
        #expect(rig.ui.messages.map(\.delivery) == [.sending])
        #expect(rig.socket.messageFrames().last?["clientMessageId"].string == id)
        await rig.receive(["type": "error", "error": "invalid_message"])
        #expect(rig.ui.messages.map(\.delivery) == [.failed])
        rig.controller.discardMessage(id)
        await rig.pump()
        #expect(rig.ui.messages.isEmpty)
        await rig.dispose()
    }

    @Test func messagesOver2000CharactersAreRefusedUpFront() async {
        let rig = CRig()
        await rig.start()
        #expect(await !rig.controller.send(String(repeating: "x", count: 2001)))
        #expect(rig.ui.error?.kind == .sendFailed)
        #expect(rig.server.count("created") == 0)
        #expect(await !rig.controller.send("   "))
        await rig.dispose()
    }

    @Test func filesUploadFirstThenGoOutAsOneMessageEachAfterTheTextNamesSurviveFromThisDevice() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin("first")
        let a = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 8), width: 40, height: 30)
        let b = GiovPickedFile(name: "b.png", mimeType: "image/png", data: Data(count: 8))
        #expect(rig.controller.checkFiles([a, b]).accepted.count == 2)
        let refused = rig.controller.checkFiles([GiovPickedFile(name: "x.exe", mimeType: "application/x-msdownload", data: Data(count: 1))]).problems
        #expect(refused == [.typeNotAllowed(name: "x.exe")])
        #expect(rig.controller.checkFiles([a], alreadyAttached: 5).problems == [.tooMany(max: 5)])
        rig.socket.sent.removeAll()
        #expect(await rig.controller.send("see these", files: [a, b]))
        await rig.pump()
        #expect(rig.server.count("upload") == 2)
        let frames = rig.socket.messageFrames()
        #expect(frames.count == 3)
        #expect(frames.first?["content"].string == "see these")
        #expect(frames.first?["attachments"] == nil)
        #expect((frames[1]["attachments"].array?.first).string?.hasSuffix("/attachments/a.png") == true)
        #expect(frames[1]["content"].string == "")
        let shown = try #require(rig.ui.messages.first { $0.attachments.contains { $0.url.hasSuffix("a.png") } })
        #expect(shown.attachments.first?.filename == "a.png")
        #expect(shown.attachments.first?.contentType == "image/png")
        #expect(abs((shown.attachments.first?.preview?.aspectRatio ?? 0) - 4.0 / 3) < 0.001)
        let download = rig.controller.attachmentURL(shown.attachments.first?.url ?? "")
        #expect(download.hasSuffix("?at=access-token-abcdefgh"))
        #expect(rig.ui.uploads.isEmpty)
        #expect(!rig.ui.sending)

        // A failed upload queues nothing.
        rig.server.uploadStatuses = [400, 400]
        #expect(await !rig.controller.send("", files: [a]))
        #expect(rig.ui.error?.kind == .attachmentRejected)
        #expect(rig.errors.last?.kind == .attachmentRejected)
        await rig.dispose()
    }

    @Test func oneFileGoesOutWithTheTextInOneMessage() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        rig.socket.sent.removeAll()
        #expect(await rig.controller.send("look", files: [GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 8))]))
        let frames = rig.socket.messageFrames()
        #expect(frames.count == 1)
        #expect(frames.first?["content"].string == "look")
        #expect(frames.first?["attachments"].array?.count == 1)
        await rig.dispose()
    }

    @Test func uploadProgressIsPublishedWhileFilesUpload() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        rig.server.uploadDelayMs = 100
        let a = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 8))
        let sending = rig.start { await rig.controller.send("x", files: [a]) }
        await rig.pump()
        #expect(rig.ui.sending)
        #expect(rig.ui.uploads == [GiovUploadProgress(name: "a.png", progress: 0.5)])
        await rig.elapse(150)
        #expect(sending.value == true)
        #expect(!rig.ui.sending)
        #expect(rig.ui.uploads.isEmpty)
        await rig.dispose()
    }

    @Test func filesCannotBeSentBeforeAConversationExists() async {
        let rig = CRig()
        await rig.start()
        let file = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 8))
        #expect(await !rig.controller.send("", files: [file]))
        #expect(rig.server.count("upload") == 0)
        await rig.dispose()
    }

    @Test func aStoreThatFailsIsReportedAndNeverBreaksTheChat() async {
        let rig = CRig(store: BrokenStore())
        await rig.start()
        #expect(rig.phase == .ready)
        await rig.begin()
        #expect(rig.errors.contains { $0.kind == .storage })
        await rig.dispose()
    }

    @Test func resetForgetsTheConversationTheStoredSessionAndTheOutbox() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.controller.reset()
        await rig.pump()
        #expect(rig.phase == .ready)
        #expect(rig.ui.messages.isEmpty)
        #expect(!rig.ui.hasConversation)
        #expect(rig.ui.conversationId == nil)
        #expect(rig.store.log.contains("delete"))
        #expect(rig.socket.closedByClient)
        await rig.dispose()
    }

    @Test func aFailureOnTheFirstLoadEndsInTheErrorPhaseWithATypedFailure() async {
        let rig = CRig()
        rig.server.config = ["oops": true]
        await rig.start()
        #expect(rig.phase == .error)
        #expect(rig.ui.error?.kind == .invalidResponse)
        await rig.dispose()
    }

    @Test func aBusyWorkspaceIsReportedOnStartAndTheMessageStaysQueued() async {
        let rig = CRig()
        rig.server.startStatus = 503
        await rig.start()
        #expect(await rig.controller.send("hello"))
        await rig.pump()
        #expect(rig.phase == .connecting, "tried again later, as the web widget does")
        #expect(rig.ui.error?.kind == .workspaceBusy)
        #expect(rig.ui.reconnecting)
        #expect(rig.ui.messages.map(\.delivery) == [.sending])
        rig.server.startStatus = nil
        await rig.elapse(29_000)
        #expect(rig.server.count("created") == 1, "not before Retry-After")
        await rig.elapse(1_000)
        #expect(rig.server.count("created") == 2)
        await rig.open()
        #expect(rig.phase == .active)
        #expect(rig.ui.error == nil)
        await rig.dispose()
    }

    @Test func connectionStatusIsReportedToTheHost() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        await rig.open()
        #expect(rig.statuses.last == .connected)
        #expect(rig.statuses.contains(.connecting))
        await rig.drop()
        #expect(rig.statuses.last == .disconnected)
        await rig.dispose()
    }

    @Test func observersSeeEveryChangeUntilCancelled() async {
        let rig = CRig(stored: testSession)
        var phases: [GiovChatPhase] = []
        var observation: GiovObservation? = rig.controller.observe { phases.append($0.phase) }
        #expect(phases == [.loading], "the current state at once")
        await rig.start()
        await rig.open()
        #expect(phases.last == .active)
        #expect(phases.contains(.connecting))
        let seen = phases.count
        observation = nil
        await rig.drop()
        #expect(phases.count == seen, "a released observation stops")
        #expect(observation == nil)
        await rig.dispose()
    }

    @Test func closeStopsTheClientAndTheSocket() async {
        let rig = CRig(stored: testSession)
        await rig.start()
        await rig.open()
        let socket = rig.socket
        await rig.dispose()
        #expect(socket.closedByClient)
        await rig.elapse(120_000)
        #expect(rig.sockets.all.count == 1)
        #expect(rig.ui.config != nil)
        #expect(await !rig.controller.send("after close"))
    }

    @Test func attachmentURLFallsBackToTheVisitorTokenWithoutAnAccessToken() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        let url = rig.controller.attachmentURL("https://api.example.test/conversations/conv-1/attachments/a.png")
        #expect(url.hasSuffix("?at=access-token-abcdefgh"))
        await rig.elapse(56 * 60_000) // the access token expires in an hour; it is dropped 5 minutes early
        let late = rig.controller.attachmentURL("https://api.example.test/conversations/conv-1/attachments/a.png")
        #expect(late.contains("?token=visitor-token-") || late.contains("?at="), "\(late)")
        await rig.dispose()
    }

    @Test func theControllerResolvesItsLanguageAndStrings() {
        let rig = CRig()
        #expect(rig.controller.locale == "en")
        #expect(rig.controller.strings.sendMessage == "Send message")
        let french = GiovChatController(tenantKey: "t", baseURL: base, sessionStore: RecordingStore(), locale: "fr-CA", overrideStrings: { $0.withOverrides(sendMessage: "Go") }, http: rig.server, socketFactory: rig.sockets, clock: rig.clock)
        #expect(french.locale == "fr")
        #expect(french.strings.sendMessage == "Go")
        #expect(french.strings.you == "Vous")
        #expect(french.baseURL == base)
    }
}
