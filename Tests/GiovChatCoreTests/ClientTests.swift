import Foundation
@testable import GiovChatCore
import Testing

@MainActor
final class ClientRig: TimeRig {
    let server: FakeServer
    let sockets = Sockets()
    let outbox: Outbox
    let recorded = RecordingEvents()
    let client: GiovChatClient

    init(flushOnOpen: Bool = true, baseURL: String = "https://api.example.test") {
        let clock = ManualClock()
        server = FakeServer(clock: clock)
        outbox = Outbox(now: { clock.now() })
        client = GiovChatClient(
            tenantKey: "t",
            baseURL: baseURL,
            outbox: outbox,
            flushOnOpen: flushOnOpen,
            http: server,
            socketFactory: sockets,
            clock: clock,
            random: { 0 }
        )
        super.init(clock: clock)
        client.events = recorded.events
    }

    /// connect() and open the socket.
    func connect() async {
        let done = startThrowing { try await self.client.connect(testSession) }
        await pump()
        sockets.last.accept()
        await pump()
        #expect(done.result != nil, "connect is still pending")
    }

    func ids(_ frames: [[String: JSONValue]]) -> [String?] { frames.map { $0["clientMessageId"].string } }

    func send(_ text: String) -> String { try! client.send(text) }
}

@MainActor
@Suite struct ClientTests {
    @Test func configRequestNamesTheSdkNoOtherRequestDoes() async throws {
        let rig = ClientRig()
        let config = try await rig.client.fetchWidgetConfig()
        #expect(config.title == "Acme")
        #expect(config.botName == "Atlas")
        #expect(rig.server.requests.first?.headers["X-Giov-Client"] == "ios/\(GiovChatVersion.current)")
        #expect(rig.server.requests.first?.url == "https://api.example.test/widget/config?tenantId=t")
        _ = try await rig.client.startConversation()
        #expect(rig.server.requests.last?.headers["X-Giov-Client"] == nil)
    }

    @Test func startSendsContactFieldsWithUserIdAndHashResumeSendsSessionSecretAsBearer() async throws {
        let rig = ClientRig()
        let hash = String(repeating: "a", count: 64)
        let started = try await rig.client.startConversation(contact: GiovContact(userId: "u1", userHash: hash, email: "a@b.co"))
        #expect(started == testSession)
        let start = try #require(rig.server.requests.last)
        #expect(start.json == json(["tenantId": "t", "userId": "u1", "userHash": hash, "email": "a@b.co"]))
        #expect(start.headers["Authorization"] == nil)
        #expect(start.headers["Content-Type"] == "application/json")

        _ = try await rig.client.resumeConversation(testSession)
        let resume = try #require(rig.server.requests.last)
        #expect(resume.headers["Authorization"] == "Bearer \(testSession.sessionToken)")
        #expect(resume.json["conversationId"].string == "conv-1")
    }

    @Test func refusalsMapToTypedFailures() async {
        let rig = ClientRig()
        rig.server.resumeStatus = 409
        #expect(await rig.failure { _ = try await rig.client.resumeConversation(testSession) }?.kind == .conversationClosed)
        rig.server.resumeStatus = 401
        #expect(await rig.failure { _ = try await rig.client.resumeConversation(testSession) }?.kind == .sessionExpired)
        rig.server.resumeStatus = 404
        let missing = await rig.failure { _ = try await rig.client.resumeConversation(testSession) }
        #expect(missing?.kind == .server && missing?.status == 404)
        rig.server.startStatus = 503
        let busy = await rig.failure { _ = try await rig.client.startConversation() }
        #expect(busy?.kind == .workspaceBusy && busy?.retryAfterSeconds == 30)
        rig.server.startStatus = 401
        rig.server.startError = "invalid_user_hash"
        #expect(await rig.failure { _ = try await rig.client.startConversation() }?.kind == .identityRejected)
        rig.server.startStatus = 429
        rig.server.startError = "rate_limited"
        #expect(await rig.failure { _ = try await rig.client.startConversation() }?.kind == .rateLimited)
        rig.server.startStatus = 401
        rig.server.startError = "unauthorized"
        #expect(await rig.failure { _ = try await rig.client.startConversation() }?.kind == .server, "401 without a session is not an expired session")
    }

    @Test func invalidConfigAndSessionResponsesAreRejected() async {
        let rig = ClientRig()
        rig.server.config = ["oops": true]
        #expect(await rig.failure { _ = try await rig.client.fetchWidgetConfig() }?.kind == .invalidResponse)
    }

    @Test func aRequestWithoutAnAnswerTimesOutAfter15s() async {
        let rig = ClientRig()
        rig.server.uploadDelayMs = 0
        let slow = SlowHTTP(clock: rig.clock)
        let client = GiovChatClient(tenantKey: "t", baseURL: "https://api.example.test", outbox: rig.outbox, http: slow, socketFactory: rig.sockets, clock: rig.clock)
        let pending = rig.startThrowing { try await client.fetchWidgetConfig() }
        await rig.elapse(14_000)
        #expect(pending.result == nil)
        await rig.elapse(1_500)
        #expect(pending.error?.kind == .network)
        #expect(pending.error?.timedOut == true)
    }

    @Test func messagesWrittenBeforeTheSocketOpensGoOutFirstInOrderUnderStableIds() async throws {
        let rig = ClientRig()
        let first = rig.send("written offline")
        let second = rig.send("and another")
        #expect(rig.outbox.count == 2)
        await rig.connect()
        let socket = rig.sockets.last
        #expect(socket.url == "wss://api.example.test/conversations/conv-1/ws?role=user&token=visitor-token-1")
        #expect(rig.server.to("/auth/widget-token").first?.headers["Authorization"] == "Bearer \(testSession.sessionToken)")
        #expect(rig.ids(socket.messageFrames()) == [first, second])
        #expect(socket.messageFrames().map { $0["content"].string } == ["written offline", "and another"])

        socket.receive([
            "type": "message_ack", "clientMessageId": first,
            "message": ["id": "srv-1", "role": "visitor", "content": "written offline", "createdAt": 5] as [String: Any?],
        ])
        await rig.pump()
        #expect(rig.recorded.acks.map { "\($0.0)>\($0.1.id)" } == ["\(first)>srv-1"])
        #expect(rig.recorded.acks.first?.1.role == .visitor)
        #expect(rig.outbox.list().map(\.clientMessageId) == [second])
        rig.client.dispose()
    }

    @Test func wsIsUsedForALocalHttpApi() async {
        let rig = ClientRig(baseURL: "http://127.0.0.1:8787")
        await rig.connect()
        #expect(rig.sockets.last.url.hasPrefix("ws://127.0.0.1:8787/conversations/conv-1/ws?role=user&token="))
        rig.client.dispose()
    }

    @Test func anAttemptThatHasNotOpenedAfterTenSecondsIsGivenUp() async {
        let rig = ClientRig()
        let done = rig.startThrowing { try await rig.client.connect(testSession) }
        await rig.elapse(9_000)
        #expect(done.result == nil)
        await rig.elapse(2_000)
        #expect(done.error?.kind == .network)
        #expect(done.error?.timedOut == true)
        #expect(rig.sockets.last.closedByClient)
        #expect(!rig.client.isConnected)
    }

    @Test func pingEvery25sAPongKeepsTheSocketAMissingPongWithin10sReconnectsWithAFreshToken() async {
        let rig = ClientRig()
        rig.sockets.autoPong = false
        await rig.connect()
        let first = rig.sockets.last
        await rig.elapse(24_000)
        #expect(first.frames("ping").isEmpty)
        await rig.elapse(1_000)
        #expect(first.frames("ping").count == 1)
        first.receive(["type": "pong"])
        await rig.elapse(11_000)
        #expect(!first.closedByClient, "the pong arrived")
        await rig.elapse(14_000) // t = 50 s: second ping
        #expect(first.frames("ping").count == 2)
        await rig.elapse(9_000)
        #expect(!first.closedByClient)
        await rig.elapse(2_000) // t = 61 s; the deadline was 60 s
        #expect(first.closedByClient, "no pong within 10 s means the socket is dead")
        #expect(!rig.client.isConnected)
        #expect(rig.sockets.all.count == 1)
        await rig.elapse(499) // 60 s + 1499 ms
        #expect(rig.sockets.all.count == 1, "first retry waits 1500 ms")
        await rig.elapse(2)
        #expect(rig.sockets.all.count == 2)
        #expect(rig.sockets.last.url.hasSuffix("token=visitor-token-2"), "a new visitor token before every connect")
        rig.client.dispose()
    }

    @Test func automaticPongsKeepTheSocketForMinutes() async {
        let rig = ClientRig()
        await rig.connect()
        await rig.elapse(5 * 60_000)
        #expect(rig.sockets.all.count == 1)
        #expect(rig.sockets.last.frames("ping").count == 12)
        #expect(rig.client.isConnected)
        rig.client.dispose()
    }

    @Test func reconnectBackoffIsMin1500TimesTwoToTheNAnd15000PlusJitter() {
        #expect((0..<7).map { giovReconnectDelayMs(attempt: $0) } == [1500, 3000, 6000, 12000, 15000, 15000, 15000])
        #expect(giovReconnectDelayMs(attempt: 0, jitter: 0.5) == 1700)
        #expect(giovReconnectDelayMs(attempt: 30, jitter: 0.999) == 15399)
        #expect(giovReconnectDelayMs(attempt: 2, jitter: 7) == 6400)
        #expect(socketOpenTimeoutMs == 10_000)
        #expect(socketPingIntervalMs == 25_000)
        #expect(socketPongTimeoutMs == 10_000)
    }

    @Test func failedReconnectAttemptsKeepBackingOffTheCounterResetsAfterASuccessfulConnect() async {
        let rig = ClientRig()
        await rig.connect()
        rig.sockets.last.drop()
        await rig.pump()
        var times: [Int] = []
        var seen = 1
        var i = 0
        while i < 400 && times.count < 4 {
            await rig.elapse(100)
            if rig.sockets.all.count > seen {
                seen = rig.sockets.all.count
                times.append(rig.elapsedMs)
            }
            i += 1
        }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        // gap = open timeout (10 s) + next backoff wait (3000, 6000, ...), measured at 100 ms resolution
        #expect(abs(gaps[0] - 13_000) <= 150)
        #expect(abs(gaps[1] - 16_000) <= 150)
        rig.sockets.last.accept()
        await rig.pump()
        rig.sockets.last.drop()
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == seen + 1, "the counter reset after the successful connect")
        rig.client.dispose()
    }

    @Test func aMessageWithNoAckWithin10sMeansADeadSocketReconnectAndResendUnderTheSameId() async {
        let rig = ClientRig()
        await rig.connect()
        let id = rig.send("are you there?")
        let first = rig.sockets.last
        #expect(first.messageFrames().count == 1)
        await rig.elapse(9_000)
        #expect(!first.closedByClient)
        await rig.elapse(4_000)
        #expect(first.closedByClient)
        #expect(rig.outbox[id]?.state == .queued, "unacknowledged stays in the outbox")
        await rig.elapse(2_000)
        rig.sockets.last.accept()
        await rig.pump()
        #expect(rig.sockets.all.count == 2)
        #expect(rig.ids(rig.sockets.last.messageFrames()) == [id])
        rig.client.dispose()
    }

    @Test func closeCode1000ConversationDeletedEndsTheConnectionWithAClosedFailureAndNoRetry() async {
        let rig = ClientRig()
        await rig.connect()
        rig.sockets.last.drop(code: 1000, reason: "Conversation deleted")
        await rig.elapse(60_000)
        #expect(rig.recorded.errors.map(\.kind) == [.conversationClosed])
        #expect(rig.sockets.all.count == 1)
    }

    @Test func anOrdinaryCloseIsADropThatReconnects() async {
        let rig = ClientRig()
        await rig.connect()
        rig.sockets.last.drop(code: 1000, reason: "bye")
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 2)
        #expect(rig.recorded.errors.isEmpty)
        rig.client.dispose()
    }

    @Test func aRefusedUpgradeCountsAsDeletedOnlyForHttp410NeverBySearchingTheErrorText() async {
        // 410 on the upgrade: the conversation is gone.
        let gone = ClientRig()
        let done = gone.startThrowing { try await gone.client.connect(testSession) }
        await gone.pump()
        gone.sockets.last.fail(410, message: "Expected HTTP 101 response but was '410 Gone'")
        await gone.pump()
        #expect(done.error?.kind == .conversationClosed)
        await gone.elapse(60_000)
        #expect(gone.sockets.all.count == 1, "no retry for a deleted conversation")

        // Any other failure whose text contains 410 (a conversation id does) is just a dropped connection.
        let id = "9c410f2e-4100-4abc-8410-000000000410"
        let other = ClientRig()
        let attempt = other.startThrowing { try await other.client.connect(testSession) }
        await other.pump()
        other.sockets.last.fail(nil, message: "Failed to connect to /conversations/\(id)/ws: Connection reset (410)")
        await other.pump()
        #expect(attempt.error?.kind == .network)
        #expect(other.recorded.errors.isEmpty)

        // 401 / 500 are not deletions either, and the failed first attempt does not retry on its own.
        let refused = ClientRig()
        let third = refused.startThrowing { try await refused.client.connect(testSession) }
        await refused.pump()
        refused.sockets.last.fail(401)
        await refused.pump()
        #expect(third.error?.kind == .network)
        await refused.elapse(60_000)
        #expect(refused.sockets.all.count == 1)
    }

    @Test func anOpenSocketThatFailsLaterReconnects() async {
        let rig = ClientRig()
        await rig.connect()
        rig.sockets.last.fail(nil)
        await rig.elapse(1_600)
        #expect(rig.sockets.all.count == 2)
        rig.sockets.last.accept()
        await rig.pump()
        rig.sockets.last.fail(101)
        await rig.elapse(1_600)
        #expect(rig.sockets.all.count == 3, "a failure after the open is a drop")
        rig.client.dispose()
    }

    @Test func saveFailuresRetryAfter2sAnd4sQuietlyThenAreReportedOnceAVisitorRetrySendsItAgain() async {
        let rig = ClientRig()
        await rig.connect()
        let socket = rig.sockets.last
        let id = rig.send("hello")
        func failed() async {
            socket.receive(["type": "error", "error": "message_failed", "clientMessageId": id])
            await rig.pump()
        }
        await failed()
        #expect(rig.outbox[id]?.state == .queued)
        await rig.elapse(1_999)
        #expect(socket.messageFrames().count == 1)
        await rig.elapse(2)
        #expect(socket.messageFrames().count == 2, "resent after 2 s")
        await failed()
        await rig.elapse(4_001)
        #expect(socket.messageFrames().count == 3, "resent after 4 s")
        #expect(rig.recorded.errors.isEmpty, "failures are retried quietly")
        await failed()
        #expect(rig.outbox[id]?.state == .failed)
        #expect(rig.recorded.errors.map(\.kind) == [.sendFailed])
        await rig.elapse(20_000)
        #expect(socket.messageFrames().count == 3, "not sent again on its own")
        #expect(rig.client.retryMessage(id))
        #expect(socket.messageFrames().count == 4)
        #expect(Set(rig.ids(socket.messageFrames())) == [id])
        rig.client.dispose()
    }

    @Test func refusalsFailTheOldestMessageOnTheSocketRateLimitsOnlyDelay() async {
        let rig = ClientRig()
        await rig.connect()
        let socket = rig.sockets.last
        let a = rig.send("a")
        let b = rig.send("b")
        socket.receive(["type": "error", "error": "invalid_message"])
        await rig.pump()
        #expect(rig.outbox[a]?.state == .failed)
        #expect(rig.outbox[b]?.state == .sending)
        #expect(rig.recorded.errors.map(\.code) == ["invalid_message"])
        socket.receive(["type": "error", "error": "rate_limited"])
        await rig.pump()
        #expect(rig.outbox[b]?.state == .queued, "rate limited: sent again a little later")
        await rig.elapse(3_000)
        #expect(rig.ids(socket.messageFrames()).filter { $0 == b }.count == 2)
        #expect(rig.ids(socket.messageFrames()).filter { $0 == a }.count == 1, "a refused message is never resent")
        rig.client.dispose()
    }

    @Test func streamedRepliesArriveAsWholeTextSoFarTheSavedReplyTakesTheDraftKeyStreamEndAloneDropsADraft() async throws {
        let rig = ClientRig()
        await rig.connect()
        let socket = rig.sockets.last
        socket.receive(["type": "stream", "streamId": "s1", "content": "Hel"])
        socket.receive(["type": "stream", "streamId": "s1", "content": "Hello **there**"])
        socket.receive([
            "id": "m1", "role": "agent", "content": "Hello **there**", "createdAt": 3,
            "isBot": true, "isAutomated": true, "streamId": "s1",
        ])
        socket.receive(["type": "stream_end", "streamId": "s2"])
        await rig.pump()
        #expect(rig.recorded.streams == ["s1:Hel", "s1:Hello **there**", "s1:end", "s2:end"])
        let message = try #require(rig.recorded.messages.first)
        #expect(rig.recorded.messages.count == 1)
        #expect(message.clientMessageId == "stream:s1")
        #expect(message.isBot)
        #expect(message.key == "stream:s1")
        rig.client.dispose()
    }

    @Test func typingAgentFramesAreReportedTheVisitorSendsTypingAndTypingEndOnceTheSocketIsOpen() async {
        let rig = ClientRig()
        rig.client.sendTyping()
        await rig.connect()
        let socket = rig.sockets.last
        rig.client.sendTyping()
        rig.client.sendTypingEnd()
        #expect(socket.types() == ["typing", "typing_end"], "nothing is sent before the socket opens")
        socket.receive(["type": "typing", "role": "agent", "isBot": true])
        socket.receive(["type": "typing_end", "role": "agent"])
        socket.receive(["type": "typing", "role": "visitor"])
        await rig.pump()
        #expect(rig.recorded.typing == ["true/true", "false/nil"])
        rig.client.dispose()
    }

    @Test func agentRepliesKeepTheirPhotoAndAttachmentsUnknownFramesAreIgnored() async throws {
        let rig = ClientRig()
        await rig.connect()
        let socket = rig.sockets.last
        socket.receive(["type": "something_new", "x": 1])
        socket.receiveRaw("not json")
        socket.receive([
            "id": "m2", "role": "agent", "content": "", "createdAt": 4, "senderName": "Ada",
            "senderAvatar": "https://cdn.test/ada.png",
            "attachmentId": #"["https://api.example.test/conversations/conv-1/attachments/a.png"]"#,
            "attachmentPreviews": [["width": 400, "height": 300]],
        ])
        await rig.pump()
        let message = try #require(rig.recorded.messages.first)
        #expect(rig.recorded.messages.count == 1)
        #expect(message.senderAvatar == "https://cdn.test/ada.png")
        #expect(message.attachments.first?.url == "https://api.example.test/conversations/conv-1/attachments/a.png")
        #expect(abs((message.attachments.first?.preview?.aspectRatio ?? 0) - 4.0 / 3) < 0.001)
        rig.client.dispose()
    }

    @Test func visitorTokensAreRenewedWhenLessThanAMinuteIsLeftKeptOtherwise() async throws {
        let rig = ClientRig()
        await rig.connect()
        #expect(rig.server.count("token") == 1)
        _ = try await rig.client.fetchHistory()
        #expect(rig.server.count("token") == 1, "the cached token is reused")
        await rig.elapse(14 * 60_000 + 10_000) // 50 s left
        _ = try await rig.client.fetchHistory()
        #expect(rig.server.count("token") == 2)
        #expect(rig.server.to("/conversations/conv-1/history").last?.headers["Authorization"] == "Bearer visitor-token-2")
        rig.client.dispose()
    }

    @Test func a401RenewsTheTokenOnceAndRetriesASecond401MeansTheSessionIsGone() async throws {
        let rig = ClientRig()
        await rig.connect()
        rig.server.historyStatuses = [401]
        _ = try await rig.client.fetchHistory()
        #expect(rig.server.count("token") == 2)
        #expect(rig.server.count("history") == 2, "one rejected, one retried")
        rig.server.historyStatuses = [401, 401]
        #expect(await rig.failure { _ = try await rig.client.fetchHistory() }?.kind == .sessionExpired)
        rig.client.dispose()
    }

    @Test func aTokenRequestInFlightIsSharedNotRepeated() async {
        let rig = ClientRig()
        await rig.connect()
        await rig.elapse(14 * 60_000 + 10_000)
        let before = rig.server.count("token")
        let a = rig.startThrowing { try await rig.client.fetchHistory() }
        let b = rig.startThrowing { try await rig.client.fetchHistory() }
        await rig.pump()
        #expect(a.result != nil && b.result != nil)
        #expect(rig.server.count("token") == before + 1)
        rig.client.dispose()
    }

    @Test func history404SurfacesAs404HistoryParsesMessagesAssigneeAndAccessToken() async throws {
        let rig = ClientRig()
        rig.server.assignedAgentName = "Ada"
        rig.server.assignedAgentAvatar = "https://cdn.test/ada.png"
        rig.server.history = [
            ["id": "h1", "role": "user", "content": "Hi", "created_at": 1],
            ["id": "h2", "role": "agent", "content": "Hello!", "created_at": 2, "is_bot": 0, "is_automated": 0],
        ]
        await rig.connect()
        let history = try await rig.client.fetchHistory()
        #expect(history.messages.map(\.id) == ["h1", "h2"])
        #expect(history.messages.first?.role == .visitor)
        #expect(history.messages.last?.senderName == "Ada", "history rows carry no sender; the assignee is used")
        #expect(history.assignedAgentAvatar == "https://cdn.test/ada.png")
        #expect(!history.closed)
        #expect(rig.recorded.access.last != nil)
        rig.server.historyStatuses = [404]
        let failure = await rig.failure { _ = try await rig.client.fetchHistory() }
        #expect(failure?.kind == .server && failure?.status == 404)
        rig.client.dispose()
    }

    @Test func callsThatNeedAConversationFailWithoutOne() async {
        let rig = ClientRig()
        #expect(await rig.failure { _ = try await rig.client.fetchHistory() }?.kind == .disconnected)
        #expect(await rig.failure { _ = try await rig.client.uploadAttachment(GiovPickedFile(name: "a", mimeType: "image/png", data: Data())) }?.kind == .disconnected)
        #expect(rig.server.requests.isEmpty)
    }

    @Test func uploadReportsProgressSendsTheFileAndAPlaceholderA401RetriesWithANewToken() async throws {
        let rig = ClientRig()
        await rig.connect()
        let file = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(repeating: 7, count: 1000), width: 40, height: 30, thumbnail: "data:image/jpeg;base64,AAAA")
        var progress: [Double] = []
        rig.server.uploadStatuses = [401]
        let result = try await rig.client.uploadAttachment(file) { progress.append($0) }
        #expect(result.url.hasSuffix("/attachments/a.png"))
        #expect(result.filename == "a.png")
        #expect(!progress.isEmpty)
        #expect(progress.last == 1)
        let uploads = rig.server.to("/conversations/conv-1/upload-visitor")
        #expect(uploads.count == 2)
        #expect(uploads.first?.headers["Authorization"] == "Bearer visitor-token-1")
        #expect(uploads.last?.headers["Authorization"] == "Bearer visitor-token-2")
        let body = try #require(uploads.last?.upload)
        #expect(body.file.mimeType == "image/png")
        #expect(body.width == 40 && body.height == 30)
        #expect(body.thumbnail == "data:image/jpeg;base64,AAAA")
        rig.client.dispose()
    }

    @Test func uploadAPlaceholderIsSentOnlyWhenAllThreeFieldsAreValid() async throws {
        let rig = ClientRig()
        await rig.connect()
        _ = try await rig.client.uploadAttachment(GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 4), width: 40, thumbnail: "data:image/jpeg;base64,AAAA"))
        #expect(rig.server.requests.last?.upload?.thumbnail == nil)
        _ = try await rig.client.uploadAttachment(GiovPickedFile(name: "a.pdf", mimeType: "application/pdf", data: Data(count: 4), width: 1, height: 1, thumbnail: "data:image/jpeg;base64,AAAA"))
        #expect(rig.server.requests.last?.upload?.thumbnail == nil)
        rig.client.dispose()
    }

    @Test func uploadARefusalIsAnAttachmentRejection() async {
        let rig = ClientRig()
        await rig.connect()
        let file = GiovPickedFile(name: "a.exe", mimeType: "application/x-msdownload", data: Data(count: 4))
        rig.server.uploadStatuses = [400]
        #expect(await rig.failure { _ = try await rig.client.uploadAttachment(file) }?.kind == .attachmentRejected)
        rig.server.uploadStatuses = [401, 403]
        #expect(await rig.failure { _ = try await rig.client.uploadAttachment(file) }?.kind == .sessionExpired)
        rig.client.dispose()
    }

    @Test func pushRegistrationSendsTokenPlatformAndApnsEnvironmentWithTheVisitorToken() async throws {
        let rig = ClientRig()
        let hex = String(repeating: "ab", count: 32)
        #expect(await rig.client.registerPushToken(hex, platform: .apns).failure == .noConversation, "nothing to register for before a conversation")
        await rig.connect()
        let result = await rig.client.registerPushToken(hex, platform: .apns, options: GiovPushOptions(environment: .sandbox, appId: "com.acme.app", locale: "fr"))
        #expect(result.registered)
        let request = try #require(rig.server.to("/conversations/conv-1/push-token", "POST").first)
        #expect(request.headers["Authorization"] == "Bearer visitor-token-1")
        #expect(request.json == json(["token": hex, "platform": "apns", "environment": "sandbox", "appId": "com.acme.app", "locale": "fr"]))
        #expect(await rig.client.unregisterPushToken(hex))
        #expect(rig.server.to("/conversations/conv-1/push-token", "DELETE").first?.json == json(["token": hex]))
        rig.client.dispose()
    }

    @Test func pushRegistrationDegradesCleanlyOnAServerWithoutItAndNeverAsksAgain() async {
        let rig = ClientRig()
        rig.server.pushStatus = 404
        await rig.connect()
        #expect(await rig.client.registerPushToken("device-token", platform: .fcm).failure == .unsupported)
        let before = rig.server.requests.count
        #expect(await rig.client.registerPushToken("device-token", platform: .fcm).failure == .unsupported)
        #expect(rig.server.requests.count == before, "an unsupported server is not asked again")
        #expect(await !rig.client.unregisterPushToken("device-token"))
        for status in [405, 501] {
            let other = ClientRig()
            other.server.pushStatus = status
            await other.connect()
            #expect(await other.client.registerPushToken("t", platform: .fcm).failure == .unsupported)
            other.client.dispose()
        }
        let failing = ClientRig()
        failing.server.pushStatus = 500
        await failing.connect()
        #expect(await failing.client.registerPushToken("t", platform: .fcm).failure == .failed)
        #expect(await failing.client.registerPushToken("", platform: .fcm).failure == .failed)
        #expect(await failing.client.registerPushToken(String(repeating: "x", count: 4097), platform: .fcm).failure == .failed)
        rig.client.dispose()
        failing.client.dispose()
    }

    @Test func disconnectKeepsUnsentMessagesANewConnectionSendsThemUnderTheSameIds() async {
        let rig = ClientRig()
        await rig.connect()
        let id = rig.send("hello")
        #expect(rig.sockets.last.messageFrames().count == 1)
        rig.client.disconnect()
        #expect(rig.outbox[id]?.state == .queued)
        #expect(rig.sockets.last.closedByClient)
        let next = GiovChatClient(tenantKey: "t", baseURL: "https://api.example.test", outbox: rig.outbox, http: rig.server, socketFactory: rig.sockets, clock: rig.clock)
        let done = rig.startThrowing { try await next.connect(testSession) }
        await rig.pump()
        rig.sockets.last.accept()
        await rig.pump()
        #expect(done.result != nil)
        #expect(rig.ids(rig.sockets.last.messageFrames()) == [id])
        next.dispose()
    }

    @Test func aDroppedSocketOfAnOpenedConnectionIsReportedAndRetriedByTheClient() async {
        let rig = ClientRig()
        await rig.connect()
        rig.sockets.last.drop()
        await rig.pump()
        #expect(Array(rig.recorded.connection.suffix(2)) == [true, false])
        await rig.elapse(1_500)
        #expect(rig.sockets.all.count == 2)
        rig.sockets.last.accept()
        await rig.pump()
        #expect(rig.client.isConnected)
        #expect(rig.recorded.connection.last == true)
        rig.client.dispose()
    }

    @Test func aReconnectWhoseTokenIsRefusedEndsTheSession() async {
        let rig = ClientRig()
        await rig.connect()
        rig.server.tokenStatuses = [401]
        rig.sockets.last.drop()
        await rig.elapse(1_500)
        #expect(rig.recorded.errors.map(\.kind) == [.sessionExpired])
        await rig.elapse(60_000)
        #expect(rig.sockets.all.count == 1)
        #expect(rig.client.session == nil)
    }

    @Test func reconnectNowSkipsTheBackoff() async {
        let rig = ClientRig()
        await rig.connect()
        rig.sockets.last.drop()
        await rig.pump()
        #expect(rig.sockets.all.count == 1)
        rig.client.reconnectNow()
        await rig.pump()
        #expect(rig.sockets.all.count == 2)
        rig.client.dispose()
    }
}

/// An HTTP seam that never answers until cancelled.
final class SlowHTTP: GiovHTTP, @unchecked Sendable {
    private let clock: ManualClock

    init(clock: ManualClock) {
        self.clock = clock
    }

    func send(_ request: GiovHTTPRequest) async throws -> GiovHTTPResponse {
        try await clock.sleep(ms: 3_600_000)
        return GiovHTTPResponse(status: 200, text: "{}")
    }
}
