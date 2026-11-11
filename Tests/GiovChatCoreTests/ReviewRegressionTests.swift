import Foundation
@testable import GiovChatCore
import Testing

// Regressions found reviewing the production paths of the core (see each test).

@Suite struct HugeNumberTests {
    @Test func numbersOutsideTheIntRangeAreRejectedInsteadOfTrapping() {
        // `Int(1e300)` traps: a single bad frame or response used to crash the host app.
        let frame = jsonValue(["id": "x", "role": "agent", "content": "c", "createdAt": 1e300])
        #expect(GiovMessage.fromJSON(frame) == nil)
        let token = VisitorToken.fromJSON(json(["token": "t", "expiresAt": 1e300]), now: 5)
        #expect(token?.expiresAt == 5 + 14 * 60_000, "falls back as if absent")
        #expect(GiovAttachmentAccess.fromJSON(jsonValue(["token": "abcdefghijklmnopqrst", "expiresAt": -1e30])) == nil)
        #expect(GiovMessage.fromJSON(jsonValue(["id": "x", "role": "agent", "content": "c", "createdAt": 1.5]))?.createdAt == 1)
        #expect(safeInt(1.8e19) == nil)
        #expect(safeInt(-.infinity) == nil)
        #expect(safeInt(-42.9) == -42)
    }
}

@MainActor
@Suite struct ReviewRegressionTests {
    @Test func aPersonsTypingEndDoesNotHideTheBotsIndicator() async {
        // visitor-realtime.asyncapi.yaml, TypingEnd: "With `isBot`, ignore it when the visible indicator belongs to
        // the other kind". The client used to drop `isBot` from typing_end.
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await rig.receive(["type": "typing", "role": "agent", "isBot": true])
        await rig.receive(["type": "typing_end", "role": "agent", "isBot": false])
        #expect(rig.ui.agentTyping)
        #expect(rig.ui.agentTypingIsBot == true)
        await rig.receive(["type": "typing_end", "role": "agent", "isBot": true])
        #expect(!rig.ui.agentTyping)
        await rig.receive(["type": "typing", "role": "agent", "isBot": false])
        await rig.receive(["type": "typing_end", "role": "agent"])
        #expect(!rig.ui.agentTyping, "without isBot it ends any indicator")
        await rig.dispose()
    }

    @Test func aResetWhileTheStoredConversationIsBeingResumedDoesNotBringItBack() async {
        let rig = CRig(stored: testSession)
        rig.server.resumeDelayMs = 1_000
        await rig.start()
        #expect(rig.server.count("resumed") == 1, "the resume request is in flight")
        let reset = rig.start { await rig.controller.reset() }
        await rig.pump()
        await rig.elapse(1_000)
        #expect(reset.isCompleted)
        #expect(rig.phase == .ready)
        #expect(rig.ui.conversationId == nil)
        // The forgotten session used to be put back by the late resume answer: the next message then went nowhere.
        #expect(await rig.controller.send("Fresh start"))
        await rig.pump()
        #expect(rig.server.count("created") == 1, "the next message starts a new conversation")
        #expect(rig.server.count("resumed") == 1)
        #expect(rig.store.log.contains("delete"))
        await rig.dispose()
    }

    @Test func aClientReleasedWithoutDisconnectingClosesItsSocketAtTheNextHeartbeat() async {
        // The socket holds its listener (and so the heartbeat's target) strongly; a controller dropped without
        // close() used to keep the connection open and pinging for ever, which also suppresses pushes.
        let time = TimeRig()
        let server = FakeServer(clock: time.clock)
        let sockets = Sockets()
        let clock = time.clock
        weak var released: GiovChatClient?
        do {
            let client = GiovChatClient(
                tenantKey: "t",
                baseURL: "https://api.example.test",
                outbox: Outbox(now: { clock.now() }),
                http: server,
                socketFactory: sockets,
                clock: clock,
                random: { 0 }
            )
            released = client
            let connected = time.startThrowing { try await client.connect(testSession) }
            await time.pump()
            sockets.last.accept()
            await time.pump()
            #expect(connected.result != nil)
        }
        await time.pump()
        #expect(released == nil, "nothing else keeps the client")
        #expect(!sockets.last.closedByClient)
        await time.elapse(25_000)
        #expect(sockets.last.closedByClient, "the orphaned socket is closed")
        let pings = sockets.last.frames("ping").count
        await time.elapse(60_000)
        #expect(sockets.last.frames("ping").count == pings, "and no longer pings")
    }

    @Test func anUpperCaseSchemeStillGivesASecureSocketURL() async {
        let rig = ClientRig(baseURL: "HTTPS://api.example.test")
        await rig.connect()
        #expect(rig.sockets.last.url.hasPrefix("wss://api.example.test/conversations/conv-1/ws?role=user&token="))
        rig.client.dispose()
    }
}
