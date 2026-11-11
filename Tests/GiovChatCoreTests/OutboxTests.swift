import Foundation
@testable import GiovChatCore
import Testing

@Suite struct OutboxTests {
    @Test func messagesLeaveInTheOrderTheyWereWrittenEachUnderOneIdForGood() throws {
        let outbox = Outbox()
        let a = try outbox.enqueue("first", now: 1, clientMessageId: "a")
        try outbox.enqueue("second", attachments: ["https://api.test/conversations/c/attachments/x"], now: 2, clientMessageId: "b")
        #expect(a.state == .queued)
        let frames = outbox.takeQueued(now: 10)
        #expect(frames.map(\.clientMessageId) == ["a", "b"])
        #expect(parse(frames[1].frame) == json([
            "type": "message", "content": "second", "clientMessageId": "b",
            "attachments": ["https://api.test/conversations/c/attachments/x"],
        ]))
        #expect(parse(frames[0].frame)["attachments"] == nil, "no attachments key without files")
        #expect(outbox.takeQueued(now: 11).isEmpty, "nothing is sent twice on the same socket")
    }

    @Test func aDroppedSocketPutsEverythingBackInLineWithTheSameIdsAnAckRemovesIt() throws {
        let outbox = Outbox()
        try outbox.enqueue("one", now: 1, clientMessageId: "one")
        try outbox.enqueue("two", now: 2, clientMessageId: "two")
        let first = outbox.takeQueued(now: 5).map(\.frame)
        outbox.socketClosed()
        #expect(outbox.list().map(\.state) == [.queued, .queued])
        #expect(outbox.list().map(\.sentAt) == [0, 0])
        #expect(outbox.takeQueued(now: 6).map(\.frame) == first, "identical frames, so the server can deduplicate")
        #expect(outbox.acknowledge("one") != nil)
        #expect(outbox.acknowledge("one") == nil, "a repeated ack is ignored")
        #expect(outbox.list().map(\.clientMessageId) == ["two"])
    }

    @Test func saveFailuresRetryAfter2sAnd4sThenGiveUpAndWaitForTheVisitor() throws {
        let outbox = Outbox()
        try outbox.enqueue("hello", now: 1, clientMessageId: "m")
        _ = outbox.takeQueued(now: 2)
        var delays: [Int] = []
        var outcome: OutboxRejection?
        for _ in 0..<maxSendFailures {
            outcome = outbox.rejected("m")
            if outcome?.failed == false {
                delays.append(outcome!.retryAfterMs)
                _ = outbox.takeQueued(now: 3)
            }
        }
        #expect(delays == [2000, 4000])
        #expect(outcome?.failed == true)
        #expect(outbox["m"]?.state == .failed)
        #expect(outbox.takeQueued(now: 4).isEmpty, "a failed message is not sent again on its own")
        outbox.socketClosed()
        #expect(outbox["m"]?.state == .failed, "reconnecting does not revive it")
        #expect(outbox.retry("m"))
        #expect(outbox.takeQueued(now: 5).map(\.clientMessageId) == ["m"])
        #expect(!outbox.retry("m"), "only failed messages can be retried")
        #expect(outbox.rejected("unknown") == nil)
    }

    @Test func aMessageUnansweredPastTheAckTimeoutMarksTheSocketAsDead() throws {
        let outbox = Outbox()
        try outbox.enqueue("hi", now: 0, clientMessageId: "x")
        #expect(!outbox.stale(now: ackTimeoutMs * 5), "queued messages never count")
        _ = outbox.takeQueued(now: 1000)
        #expect(!outbox.stale(now: 1000 + ackTimeoutMs))
        #expect(outbox.stale(now: 1001 + ackTimeoutMs))
    }

    @Test func refusalsFailTheOldestMessageOnTheSocketEmptyAndOversizedMessagesAreRejectedUpFront() throws {
        let outbox = Outbox()
        try outbox.enqueue("a", now: 1, clientMessageId: "a")
        try outbox.enqueue("b", now: 2, clientMessageId: "b")
        _ = outbox.takeQueued(now: 3)
        #expect(outbox.refuseOldestSending()?.clientMessageId == "a")
        #expect(outbox.list().map(\.state) == [.failed, .sending])
        for bad in ["   ", String(repeating: "x", count: 2001)] {
            #expect(throws: GiovChatError.self) { try outbox.enqueue(bad) }
        }
        do {
            try outbox.enqueue(String(repeating: "x", count: 2001))
        } catch {
            #expect(error.kind == .sendFailed)
        }
        try outbox.enqueue("", attachments: ["https://api.test/a"]) // a file alone is a message
        try outbox.enqueue(String(repeating: "x", count: 2000))
    }

    @Test func listenersHearEveryChangeClientIdsAreUniqueUuids() throws {
        let outbox = Outbox()
        var changes = 0
        let stop = outbox.subscribe { changes += 1 }
        try outbox.enqueue("a", now: 1, clientMessageId: "a")
        _ = outbox.takeQueued(now: 2)
        outbox.acknowledge("a")
        stop()
        try outbox.enqueue("b")
        #expect(changes == 3)
        let ids = Set((0..<200).map { _ in randomClientId() })
        #expect(ids.count == 200)
        let uuid = Pattern("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z")
        #expect(uuid.matches(ids.first!))
    }

    @Test func theFrameCarriesAttachmentsAsAnArrayOfUrls() throws {
        let entry = try Outbox().enqueue("see", attachments: ["u1", "u2"], clientMessageId: "z")
        #expect(parse(Outbox.frame(entry))["attachments"] == .array([.string("u1"), .string("u2")]))
    }

    @Test func removeAndClearDropMessages() throws {
        let outbox = Outbox()
        try outbox.enqueue("a", clientMessageId: "a")
        try outbox.enqueue("b", clientMessageId: "b")
        #expect(outbox.remove("a"))
        #expect(!outbox.remove("a"))
        outbox.clear()
        #expect(outbox.count == 0)
    }
}
