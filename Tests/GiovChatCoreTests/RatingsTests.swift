import Foundation
@testable import GiovChatCore
import Testing

private let soon = epoch + 3_600_000
private let later = epoch + 86_400_000
private let fixtureText = "How did we do? Please rate this conversation."

private typealias Answer = (status: Int, body: [String: Any?], headers: [String: String])

private func card(_ id: String = "r1", request: String = "req-1", closesAt: Int = soon, createdAt: Int = 20, extra: [String: Any?] = [:], isBot: Bool = false) -> [String: Any?] {
    var block: [String: Any?] = ["type": "rating", "requestId": request, "closesAt": closesAt]
    for (key, value) in extra { block[key] = value }
    var message: [String: Any?] = [
        "id": id, "role": "agent", "content": fixtureText, "createdAt": createdAt, "senderName": "Ada",
        "blocks": [block] as [Any?],
    ]
    if isBot { message["isBot"] = true }
    return message
}

private func saved(request: String = "req-1", score: Int, comment: String? = nil, closesAt: Int = later) -> Answer {
    (200, ["requestId": request, "score": score, "comment": comment, "closesAt": closesAt, "ratedAt": epoch] as [String: Any?], [:])
}

@MainActor
private func deliver(_ rig: CRig, _ message: [String: Any?]) async {
    rig.socket.receiveRaw(jsonValue(message).serialized)
    await rig.pump()
}

@MainActor
private func ratingBlock(_ rig: CRig, _ id: String = "r1") -> GiovRatingBlock? {
    rig.ui.messages.first { $0.id == id }?.rating
}

// MARK: - Parsing and patching

@Suite struct RatingParsingTests {
    @Test func aRatingBlockIsReadFromAMessageAndOtherBlocksAreIgnored() throws {
        let message = try #require(GiovMessage.fromJSON(jsonValue([
            "id": "m", "role": "agent", "content": fixtureText, "createdAt": 5,
            "blocks": [
                ["type": "buttons", "buttons": [] as [Any?]] as [String: Any?],
                ["type": "form", "title": "x"] as [String: Any?],
                ["type": "rating", "requestId": "req-1", "closesAt": soon, "url": "https://giov.test/rate/req-1#k=abc"] as [String: Any?],
                ["type": "from-the-future", "x": 1] as [String: Any?],
            ] as [Any?],
        ] as [String: Any?])))
        #expect(message.rating == GiovRatingBlock(requestId: "req-1", closesAt: soon, url: "https://giov.test/rate/req-1#k=abc"))
        #expect(message.rating?.url?.contains("#k=") == true, "the fragment is kept as given, never parsed")
    }

    @Test func aBlockWithoutRequestIdOrDeadlineAndNonRatingBlocksAreNotRatings() {
        for block in [
            ["type": "rating", "closesAt": soon] as [String: Any?],
            ["type": "rating", "requestId": "r"] as [String: Any?],
            ["type": "rating", "requestId": "", "closesAt": soon] as [String: Any?],
            ["type": "card", "requestId": "r", "closesAt": soon] as [String: Any?],
        ] {
            #expect(GiovRatingBlock.fromJSON(jsonValue(block)) == nil)
        }
        #expect(GiovMessage.fromJSON(jsonValue(["id": "m", "role": "agent", "content": "x", "createdAt": 1] as [String: Any?]))?.rating == nil)
    }

    @Test func theAnswerComesWithTheBlockAndAnOutOfRangeScoreIsIgnored() {
        let answered = GiovRatingBlock.fromJSON(jsonValue(["type": "rating", "requestId": "r", "closesAt": soon, "score": 4, "comment": "Quick"] as [String: Any?]))
        #expect(answered?.score == 4 && answered?.comment == "Quick")
        for bad in [0, 6, -1] as [Int] {
            let block = GiovRatingBlock.fromJSON(jsonValue(["type": "rating", "requestId": "r", "closesAt": soon, "score": bad, "comment": "x"] as [String: Any?]))
            #expect(block?.score == nil && block?.comment == nil)
        }
        let fraction = GiovRatingBlock.fromJSON(jsonValue(["type": "rating", "requestId": "r", "closesAt": soon, "score": 3.5] as [String: Any?]))
        #expect(fraction?.score == nil)
        #expect(GiovRatingBlock.fromJSON(jsonValue(["type": "rating", "requestId": "r", "closesAt": soon, "state": "replaced"] as [String: Any?]))?.replaced == true)
    }

    @Test func aGiovBotVoteComesWithHistoryRowsOfBotAnswersOnly() throws {
        let bot = try #require(GiovMessage.fromJSON(jsonValue(["id": "b", "role": "agent", "content": "x", "createdAt": 1, "isBot": true, "feedback": "down"] as [String: Any?])))
        #expect(bot.feedback == .down)
        let person = try #require(GiovMessage.fromJSON(jsonValue(["id": "p", "role": "agent", "content": "x", "createdAt": 1, "feedback": "up"] as [String: Any?])))
        #expect(person.feedback == nil)
        let odd = try #require(GiovMessage.fromJSON(jsonValue(["id": "o", "role": "agent", "content": "x", "createdAt": 1, "isBot": true, "feedback": "maybe"] as [String: Any?])))
        #expect(odd.feedback == nil)
    }

    @Test func theFrameIsParsedDefensively() throws {
        let frame = try #require(GiovRatingFrame.fromJSON(parse(#"{"type":"rating","conversationId":"c","requestId":"r","messageId":"m","closesAt":5,"score":5,"comment":"ok","extra":1}"#)))
        #expect(frame == GiovRatingFrame(requestId: "r", messageId: "m", closesAt: 5, score: 5, comment: "ok"))
        let none = try #require(GiovRatingFrame.fromJSON(parse(#"{"type":"rating","requestId":"r","closesAt":5,"comment":"orphan"}"#)))
        #expect(none.score == nil && none.comment == nil && none.messageId == nil)
        let replaced = try #require(GiovRatingFrame.fromJSON(parse(#"{"type":"rating","requestId":"r","closesAt":5,"state":"replaced"}"#)))
        #expect(replaced.replaced)
        #expect(GiovRatingFrame.fromJSON(parse(#"{"type":"rating","closesAt":5}"#)) == nil)
        #expect(GiovRatingFrame.fromJSON(parse(#"{"type":"rating","requestId":"r"}"#)) == nil)
        #expect(GiovRatingFrame.fromJSON(parse(#"{"type":"message","requestId":"r","closesAt":5}"#)) == nil)
    }

    private func message(_ id: String, request: String, score: Int? = nil, replaced: Bool = false) -> GiovMessage {
        GiovMessage(id: id, role: .agent, content: fixtureText, createdAt: 1, rating: GiovRatingBlock(requestId: request, closesAt: soon, score: score, replaced: replaced))
    }

    @Test func aFramePatchesOnlyTheCardItNames() {
        let list = [message("a", request: "r1"), message("b", request: "r2"), GiovMessage(id: "c", role: .agent, content: "hi", createdAt: 3)]
        let answered = patchRating(list, GiovRatingFrame(requestId: "r2", messageId: "b", closesAt: later, score: 5, comment: "yes"))
        #expect(answered[0] == list[0] && answered[2] == list[2])
        #expect(answered[1].rating?.score == 5 && answered[1].rating?.comment == "yes" && answered[1].rating?.closesAt == later)
        // A frame for another message id leaves it alone; one without a score clears the answer.
        #expect(patchRating(list, GiovRatingFrame(requestId: "r2", messageId: "zzz", closesAt: later, score: 5)) == list)
        #expect(patchRating(answered, GiovRatingFrame(requestId: "r2", messageId: nil, closesAt: soon)).map(\.rating?.score) == [nil, nil, nil])
        let replaced = patchRating(list, GiovRatingFrame(requestId: "r1", messageId: "a", closesAt: soon, replaced: true))
        #expect(replaced[0].rating?.replaced == true && replaced[1].rating?.replaced == false)
    }

    @Test func aNewerCardHidesOlderUnansweredOnesButNotAnsweredOnes() {
        let list = [message("a", request: "r1"), message("b", request: "r2", score: 4), message("c", request: "r3")]
        let next = replaceOlderRatings(list)
        #expect(next.map { $0.rating?.replaced } == [true, false, false])
        #expect(replaceOlderRatings([message("a", request: "r1")]).first?.rating?.replaced == false, "a single card stays")
    }

    @Test func theOpenRequestIsTheNewestCardNotReplacedAndNotPastItsDeadline() {
        let list = [message("a", request: "r1"), message("b", request: "r2", replaced: true)]
        #expect(openRatingRequest(list, now: epoch)?.requestId == "r1")
        #expect(openRatingRequest(list, now: soon) == nil, "closed at closesAt")
        #expect(openRatingRequest([], now: epoch) == nil)
    }

    @Test func thumbsGoUnderFinishedBotAnswersOnly() {
        #expect(GiovMessage(id: "1", role: .agent, content: "x", createdAt: 1, isBot: true).allowsAnswerFeedback)
        #expect(!GiovMessage(id: "1", role: .agent, content: "x", createdAt: 1, isBot: true, isStreaming: true).allowsAnswerFeedback)
        #expect(!GiovMessage(id: "1", role: .agent, content: "x", createdAt: 1).allowsAnswerFeedback)
        #expect(!GiovMessage(id: "1", role: .visitor, content: "x", createdAt: 1).allowsAnswerFeedback)
        let botCard = GiovMessage(id: "1", role: .agent, content: fixtureText, createdAt: 1, isBot: true, rating: GiovRatingBlock(requestId: "r", closesAt: soon))
        #expect(!botCard.allowsAnswerFeedback, "the rating card GiovBot sends gets no thumbs")
    }
}

// MARK: - The card's state machine

@Suite struct RatingCardStateTests {
    private let block = GiovRatingBlock(requestId: "r", closesAt: 1000)

    @Test func pendingAnsweredChangedClosedReplaced() {
        // pending: the form, nothing picked, no way back
        #expect(GiovRatingCardState.make(block: block, now: 0) == .form(selected: nil, comment: "", canCancel: false))
        #expect(GiovRatingCardState.make(block: block, now: 0, selected: 3, comment: "hm") == .form(selected: 3, comment: "hm", canCancel: false))
        // answered
        var answered = block
        answered.score = 4
        answered.comment = "Quick"
        #expect(GiovRatingCardState.make(block: answered, now: 0) == .answered(score: 4, comment: "Quick", canChange: true))
        // changed: back to the form with a way to cancel
        #expect(GiovRatingCardState.make(block: answered, now: 0, editing: true, selected: 4) == .form(selected: 4, comment: "", canCancel: true))
        // closed with an answer: read-only
        #expect(GiovRatingCardState.make(block: answered, now: 1000) == .answered(score: 4, comment: "Quick", canChange: false))
        #expect(GiovRatingCardState.make(block: answered, now: 1000, editing: true) == .answered(score: 4, comment: "Quick", canChange: false))
        // closed without an answer
        #expect(GiovRatingCardState.make(block: block, now: 1000) == .closed)
        // replaced: nothing, whatever else
        var replaced = answered
        replaced.replaced = true
        #expect(GiovRatingCardState.make(block: replaced, now: 0) == .hidden)
        #expect(GiovRatingCardState.make(block: block, now: 0, lock: .replaced) == .hidden)
    }

    @Test func aRefusalLocksTheCard() {
        var answered = block
        answered.score = 2
        #expect(GiovRatingCardState.make(block: answered, now: 0, lock: .closed) == .answered(score: 2, comment: nil, canChange: false))
        #expect(GiovRatingCardState.make(block: answered, now: 0, lock: .tooManyChanges) == .answered(score: 2, comment: nil, canChange: false))
        #expect(GiovRatingCardState.make(block: block, now: 0, lock: .closed) == .closed)
        #expect(GiovRatingCardState.make(block: block, now: 0, lock: .retry) == .form(selected: nil, comment: "", canCancel: false))
    }

    @Test func facesWrapAroundAndTextIsClamped() {
        #expect(GiovRatingCardState.step(from: nil, by: 1) == 2)
        #expect(GiovRatingCardState.step(from: 5, by: 1) == 1)
        #expect(GiovRatingCardState.step(from: 1, by: -1) == 5)
        #expect(GiovRatingCardState.step(from: 3, by: -1) == 2)
        #expect(GiovRatingCardState.clampComment(String(repeating: "a", count: 1200)).utf16.count == 1000)
        #expect(GiovRatingCardState.clampComment("short") == "short")
        // an emoji is two UTF-16 units and is never split
        let emoji = String(repeating: "\u{1F600}", count: 600)
        let cut = GiovRatingCardState.clampComment(emoji)
        #expect(cut.utf16.count == 1000 && cut.unicodeScalars.count == 500)
        #expect(GiovRatingCardState.clampReason(String(repeating: "b", count: 400)).utf16.count == 300)
    }

    @Test func refusalsMapToTheirFailure() {
        func failure(_ status: Int, _ code: String?, kind: GiovChatError.Kind = .server, retry: Int? = nil) -> GiovRatingFailure {
            GiovChatError(kind, "x", status: status, code: code, retryAfterSeconds: retry).ratingFailure
        }
        #expect(failure(409, "rating_closed") == .closed)
        #expect(failure(409, "request_replaced") == .replaced)
        #expect(failure(429, "too_many_changes", kind: .rateLimited, retry: 30) == .tooManyChanges)
        #expect(failure(400, "invalid_rating") == .invalid)
        #expect(failure(400, "invalid_feedback") == .invalid)
        #expect(failure(404, "request_not_found") == .notFound)
        #expect(failure(404, "message_not_found") == .notFound)
        #expect(failure(429, "rate_limited", kind: .rateLimited, retry: 12) == .rateLimited(retryAfterSeconds: 12))
        #expect(failure(404, "not_found") == .unsupported)
        #expect(failure(404, nil) == .unsupported)
        #expect(failure(500, nil) == .retry)
        #expect(GiovChatError.network("x").ratingFailure == .retry)
        #expect(GiovChatError.sessionExpired("x", status: 401).ratingFailure == .retry)
    }

    @Test func everyLanguageHasFiveFacesAndAllText() {
        for (code, strings) in GiovChatStrings.all {
            let r = strings.rating
            #expect(r.faces.count == 5 && !r.faces.contains { $0.isEmpty }, "\(code)")
            #expect(Set(r.faces).count == 5, "\(code) faces are distinct")
            let plain = [r.title, r.yourRating, r.commentPlaceholder, r.send, r.cancel, r.change, r.closed, r.couldNotSend, r.goodAnswer, r.badAnswer, r.rateAnswer, r.reasonPlaceholder, r.skip, r.couldNotSave, r.thanks(r.face(4))]
            for text in plain { #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(code)") }
            #expect(r.thanks("X").contains("X"), "\(code)")
            #expect(r.face(0) == "" && r.face(6) == "")
        }
        #expect(GiovChatStrings.en.rating.faces == ["Very bad", "Bad", "Okay", "Good", "Great"])
        #expect(GiovChatStrings.en.rating.describe(.closed) == nil)
        #expect(GiovChatStrings.en.rating.describe(.retry) == "Couldn't send. Please try again.")
        let custom = GiovChatStrings.en.withOverrides(rating: GiovRatingStrings.fr)
        #expect(custom.rating.send == "Envoyer")
    }
}

// MARK: - The controller

@MainActor
@Suite struct RatingControllerTests {
    @Test func aCardFromTheTeamIsReportedOnceAndKnownAsThePendingRequest() async {
        let rig = CRig()
        var requested: [GiovRatingRequest] = []
        rig.controller.onRatingRequested = { requested.append($0) }
        await rig.start()
        await rig.begin()
        #expect(rig.controller.pendingRating == nil)
        await deliver(rig, card())
        #expect(requested == [GiovRatingRequest(messageId: "r1", requestId: "req-1", closesAt: soon)])
        #expect(rig.controller.pendingRating?.requestId == "req-1")
        #expect(rig.ui.ratingRequest?.messageId == "r1")
        #expect(rig.ui.ratingRequest?.isAnswered == false)
        await deliver(rig, card())
        #expect(requested.count == 1, "the same request is reported once")
        await rig.dispose()
    }

    @Test func answeringShowsAtOnceSendsTheVisitorTokenAndReportsTheResult() async throws {
        let rig = CRig()
        var results: [GiovRatingResult] = []
        rig.controller.onRatingSubmitted = { results.append($0) }
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        rig.server.ratingResponder = { _ in saved(score: 4, comment: "Quick answer") }
        let result = try await rig.controller.submitRating(score: 4, comment: "  Quick answer ")
        #expect(result == GiovRatingResult(requestId: "req-1", score: 4, comment: "Quick answer", closesAt: later, ratedAt: epoch))
        #expect(results == [result])
        let sent = try #require(rig.server.to("/conversations/conv-1/rating", "POST").last)
        #expect(sent.json == json(["requestId": "req-1", "score": 4, "comment": "Quick answer"]))
        #expect(sent.headers["Authorization"]?.hasPrefix("Bearer visitor-token-") == true)
        let block = try #require(ratingBlock(rig))
        #expect(block.score == 4 && block.comment == "Quick answer" && block.closesAt == later)
        #expect(rig.ui.ratingRequest?.isAnswered == true)
        await rig.dispose()
    }

    @Test func theVisitorMayChangeTheAnswerAndTheOpenCardIsUsedWithoutARequestId() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        rig.server.ratingResponder = { request in saved(score: request.json["score"].int ?? 0) }
        try await rig.controller.submitRating(score: 3)
        try await rig.controller.submitRating(score: 5)
        let sent = rig.server.to("/conversations/conv-1/rating", "POST")
        #expect(sent.map { $0.json["score"].int } == [3, 5])
        #expect(sent.allSatisfy { $0.json["requestId"].string == "req-1" })
        #expect(sent.allSatisfy { $0.json["comment"] == nil }, "no comment, none sent")
        #expect(ratingBlock(rig)?.score == 5 && ratingBlock(rig)?.comment == nil)
        await rig.dispose()
    }

    @Test func aFailureRollsTheAnswerBackAndSayingWhyIsTypedPerCode() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())

        rig.server.ratingResponder = { _ in (500, ["error": "boom"], [:]) }
        var error = try await expectFailure { try await rig.controller.submitRating(score: 2) }
        #expect(error.ratingFailure == .retry)
        #expect(ratingBlock(rig)?.score == nil, "rolled back")
        #expect(ratingBlock(rig)?.phase(at: rig.now) == .open)

        rig.server.ratingResponder = { _ in (429, ["error": "too_many_changes"], ["retry-after": "30"]) }
        error = try await expectFailure { try await rig.controller.submitRating(score: 2) }
        #expect(error.ratingFailure == .tooManyChanges)
        #expect(ratingBlock(rig)?.phase(at: rig.now) == .closed, "read-only after too many changes")

        rig.server.ratingResponder = { _ in (409, ["error": "rating_closed"], [:]) }
        error = try await expectFailure { try await rig.controller.submitRating(score: 2, requestId: "req-1") }
        #expect(error.ratingFailure == .closed)
        #expect(error.status == 409 && error.kind == .server, "a 409 on this route is not 'conversation closed'")
        #expect(rig.ui.phase == .active, "the chat itself is untouched")
        await rig.dispose()
    }

    @Test func aRateLimitCarriesTheRetryAfterAndAReplacedCardHides() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        rig.server.ratingResponder = { _ in (429, ["error": "rate_limited"], ["retry-after": "12"]) }
        var error = try await expectFailure { try await rig.controller.submitRating(score: 1) }
        #expect(error.ratingFailure == .rateLimited(retryAfterSeconds: 12))
        #expect(ratingBlock(rig)?.score == nil)
        rig.server.ratingResponder = { _ in (409, ["error": "request_replaced"], [:]) }
        error = try await expectFailure { try await rig.controller.submitRating(score: 1) }
        #expect(error.ratingFailure == .replaced)
        #expect(ratingBlock(rig)?.replaced == true)
        #expect(rig.ui.ratingRequest == nil)
        await rig.dispose()
    }

    @Test func aBadScoreNeverLeavesTheDevice() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        for score in [0, 6, -3] {
            let error = try await expectFailure { try await rig.controller.submitRating(score: score) }
            #expect(error.ratingFailure == .invalid && error.code == "invalid_rating")
        }
        #expect(rig.server.count("rating") == 0)
        await rig.dispose()
    }

    @Test func aServerWithoutTheRouteHidesTheCard() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        #expect(rig.ui.ratingsAvailable)
        let error = try await expectFailure { try await rig.controller.submitRating(score: 3) }
        #expect(error.ratingFailure == .unsupported)
        #expect(!rig.ui.ratingsAvailable)
        let calls = rig.server.count("rating")
        _ = try await expectFailure { try await rig.controller.submitRating(score: 3) }
        #expect(rig.server.count("rating") == calls, "it stops asking")
        await rig.dispose()
    }

    @Test func aRequestNotFoundIsNotAnOldServer() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        rig.server.ratingResponder = { _ in (404, ["error": "request_not_found"], [:]) }
        let error = try await expectFailure { try await rig.controller.submitRating(score: 3, requestId: "gone") }
        #expect(error.ratingFailure == .notFound)
        #expect(rig.ui.ratingsAvailable)
        await rig.dispose()
    }

    @Test func theRatingFramePatchesTheCardLiveAndReplacementHidesIt() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card())
        await rig.receive(["type": "rating", "conversationId": "conv-1", "requestId": "req-1", "messageId": "r1", "closesAt": later, "score": 5, "comment": "From my tablet"])
        #expect(ratingBlock(rig)?.score == 5 && ratingBlock(rig)?.comment == "From my tablet" && ratingBlock(rig)?.closesAt == later)
        await rig.receive(["type": "rating", "conversationId": "conv-1", "requestId": "req-1", "messageId": "r1", "closesAt": later])
        #expect(ratingBlock(rig)?.score == nil, "a frame without a score means no answer")
        await rig.receive(["type": "rating", "conversationId": "conv-1", "requestId": "req-1", "messageId": "r1", "closesAt": later, "state": "replaced"])
        #expect(ratingBlock(rig)?.replaced == true)
        #expect(rig.ui.ratingRequest == nil)
        await rig.receive(["type": "rating", "requestId": "unknown", "closesAt": later, "score": 2])
        await rig.receive(["type": "rating"])
        #expect(rig.ui.phase == .active, "odd frames are ignored")
        await rig.dispose()
    }

    @Test func aNewerCardHidesTheOlderUnansweredOne() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card("r1", request: "req-1", createdAt: 20))
        await deliver(rig, card("r2", request: "req-2", createdAt: 30))
        #expect(ratingBlock(rig, "r1")?.replaced == true)
        #expect(ratingBlock(rig, "r2")?.replaced == false)
        #expect(rig.controller.pendingRating?.requestId == "req-2")
        await rig.dispose()
    }

    @Test func aCardIsReadOnlyOnceItsDeadlinePasses() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, card(closesAt: epoch + 60_000))
        #expect(rig.controller.pendingRating != nil)
        await rig.elapse(61_000)
        #expect(rig.controller.pendingRating == nil)
        #expect(ratingBlock(rig)?.phase(at: rig.now) == .closed)
        await rig.dispose()
    }

    @Test func historyReturnsTheCardWithTheAnswerAppliedAndTheVote() async {
        let rig = CRig(stored: testSession)
        var bot = ["id": "b1", "role": "agent", "content": "Try restarting", "createdAt": 10, "isBot": true, "isAutomated": true, "feedback": "up"] as [String: Any?]
        bot["blocks"] = nil
        rig.server.history = [
            bot,
            card("r1", extra: ["score": 4, "comment": "Quick"]),
        ]
        await rig.start()
        await rig.open()
        #expect(ratingBlock(rig)?.score == 4 && ratingBlock(rig)?.comment == "Quick")
        #expect(rig.ui.messages.first { $0.id == "b1" }?.feedback == .up)
        await rig.dispose()
    }

    @Test func aCardOnAClosedConversationRendersAndSubmitsThenANewConversationClearsIt() async throws {
        let rig = CRig(stored: testSession)
        rig.server.status = "closed"
        rig.server.history = [card()]
        var requested = 0
        rig.controller.onRatingRequested = { _ in requested += 1 }
        await rig.start()
        await rig.open()
        #expect(rig.ui.conversationClosed, "the conversation is read-only")
        #expect(rig.phase == .active)
        #expect(rig.controller.pendingRating?.requestId == "req-1", "but the open card is kept and interactive")
        #expect(rig.ui.ratingRequest != nil && rig.ui.showsRatingCard)
        #expect(requested == 1)
        rig.server.ratingResponder = { _ in saved(score: 5) }
        try await rig.controller.submitRating(score: 5)
        let sent = try #require(rig.server.to("/conversations/conv-1/rating", "POST").last)
        #expect(sent.headers["Authorization"]?.hasPrefix("Bearer visitor-token-") == true)
        #expect(ratingBlock(rig)?.score == 5)
        await rig.controller.startNewConversation()
        #expect(!rig.ui.conversationClosed)
        #expect(rig.ui.messages.isEmpty && rig.controller.pendingRating == nil, "the old card goes with the old conversation")
        await rig.dispose()
    }

    @Test func theConversationStateFrameSwitchesTheClosedViewAtOnce() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        #expect(!rig.ui.conversationClosed)
        await rig.receive(["type": "conversation_state", "handedOff": true, "assignedAgentName": "Ada", "status": "closed"])
        #expect(rig.ui.conversationClosed, "read-only straight away, no history reload needed")
        #expect(rig.phase == .active)
        await deliver(rig, card())
        #expect(rig.controller.pendingRating != nil, "a card after the close renders")
        await rig.receive(["type": "conversation_state", "handedOff": true, "assignedAgentName": "Ada", "status": "open"])
        #expect(!rig.ui.conversationClosed, "reopened")
        await rig.receive(["type": "conversation_state", "handedOff": false])
        await rig.receive(["type": "conversation_state", "status": "weird"])
        #expect(!rig.ui.conversationClosed, "no or unknown status changes nothing")
        await rig.receive(["type": "conversation_state", "status": "closed"])
        await rig.receive(["type": "conversation_state", "handedOff": true])
        #expect(rig.ui.conversationClosed, "a frame without status leaves the state alone")
        await rig.dispose()
    }

    @Test func aCardThatArrivesAfterTheCloseRenders() async throws {
        let rig = CRig(stored: testSession)
        rig.server.status = "closed"
        rig.server.history = [["id": "h1", "role": "user", "content": "Hi", "createdAt": 1]]
        await rig.start()
        await rig.open()
        #expect(rig.ui.conversationClosed && rig.controller.pendingRating == nil)
        await deliver(rig, card("r9", request: "req-9", createdAt: 50))
        #expect(rig.controller.pendingRating?.requestId == "req-9")
        #expect(ratingBlock(rig, "r9") != nil, "the card is in the list the screen draws")
        #expect(rig.ui.conversationClosed, "still read-only")
        rig.server.ratingResponder = { _ in saved(request: "req-9", score: 4) }
        try await rig.controller.submitRating(score: 4)
        #expect(ratingBlock(rig, "r9")?.score == 4)
        await rig.dispose()
    }

    @Test func presentingTheSheetNeedsAnOpenRequestAndClosesWhenItEnds() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        #expect(!rig.controller.presentRating())
        await deliver(rig, card())
        #expect(rig.controller.presentRating())
        #expect(rig.ui.ratingSheetPresented)
        rig.controller.dismissRating()
        #expect(!rig.ui.ratingSheetPresented)
        #expect(rig.controller.presentRating())
        await rig.receive(["type": "rating", "requestId": "req-1", "messageId": "r1", "closesAt": later, "state": "replaced"])
        #expect(!rig.ui.ratingSheetPresented, "nothing left to rate")
        await rig.dispose()
    }

    @Test func theHostCanTurnTheBuiltInCardAndThumbsOff() async {
        let rig = CRig()
        #expect(rig.ui.showsRatingCard && rig.ui.showsAnswerFeedback)
        let off = GiovChatController(tenantKey: "t", baseURL: "https://api.example.test", sessionStore: RecordingStore(), locale: "en", showsRatingCard: false, showsAnswerFeedback: false, http: rig.server, socketFactory: rig.sockets, clock: rig.clock)
        #expect(!off.state.showsRatingCard && !off.state.showsAnswerFeedback)
        off.close()
        await rig.dispose()
    }

    // MARK: Thumbs

    private func botAnswer(_ id: String = "b1") -> [String: Any?] {
        ["id": id, "role": "agent", "content": "Try restarting", "createdAt": 10, "isBot": true]
    }

    @Test func aVoteShowsAtOnceIsSentAndTakenBackWithNone() async throws {
        let rig = CRig()
        var votes: [(String, GiovAnswerVote?)] = []
        rig.controller.onAnswerFeedback = { votes.append(($0, $1)) }
        await rig.start()
        await rig.begin()
        await deliver(rig, botAnswer())
        rig.server.feedbackResponder = { _ in (200, ["messageId": "b1", "value": "up", "reason": nil], [:]) }
        try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .up)
        #expect(rig.ui.messages.first { $0.id == "b1" }?.feedback == .up)
        try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: nil)
        #expect(rig.ui.messages.first { $0.id == "b1" }?.feedback == nil)
        let sent = rig.server.to("/conversations/conv-1/messages/b1/feedback", "POST")
        #expect(sent.map { $0.json["value"].string } == ["up", "none"])
        #expect(votes.count == 2 && votes[0].1 == .up && votes[1].1 == nil)
        await rig.dispose()
    }

    @Test func aThumbsDownCarriesTheReasonAndOnlyThen() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, botAnswer())
        rig.server.feedbackResponder = { _ in (200, ["messageId": "b1", "value": "down", "reason": "wrong"], [:]) }
        try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .down)
        try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .down, reason: "  Not my model ")
        try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .up, reason: "ignored")
        try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .down, reason: String(repeating: "x", count: 500))
        let sent = rig.server.to("/conversations/conv-1/messages/b1/feedback", "POST")
        #expect(sent[0].json == json(["value": "down"]))
        #expect(sent[1].json == json(["value": "down", "reason": "Not my model"]))
        #expect(sent[2].json == json(["value": "up"]))
        #expect(sent[3].json["reason"].string?.utf16.count == 300)
        await rig.dispose()
    }

    @Test func aRefusedVoteIsRolledBack() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, botAnswer())
        rig.server.feedbackResponder = { _ in (404, ["error": "message_not_found"], [:]) }
        let error = try await expectFailure { try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .down) }
        #expect(error.ratingFailure == .notFound)
        #expect(rig.ui.messages.first { $0.id == "b1" }?.feedback == nil)
        #expect(rig.ui.feedbackAvailable)
        await rig.dispose()
    }

    @Test func aServerWithoutTheFeedbackRouteHidesTheThumbs() async throws {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        await deliver(rig, botAnswer())
        let error = try await expectFailure { try await rig.controller.submitAnswerFeedback(messageId: "b1", vote: .up) }
        #expect(error.ratingFailure == .unsupported)
        #expect(!rig.ui.feedbackAvailable)
        #expect(rig.ui.ratingsAvailable, "the rating route is judged on its own")
        await rig.dispose()
    }

    // MARK: Conformance fixture

    /// Replays the visitor side of `Fixtures/05-ratings.json` (a copy of docs/protocol/conformance/fixtures): every
    /// request the fixture makes with the visitor token goes through the SDK's public API against a server that
    /// answers what the fixture expects, and every frame it expects the socket to deliver is delivered and checked.
    @Test func fixture05RatingsReplays() async throws {
        let url = try #require(Bundle.module.url(forResource: "05-ratings", withExtension: "json", subdirectory: "Fixtures"))
        let document = try #require(JSONValue.parse(try Data(contentsOf: url)))
        let steps = try #require(document["steps"].array)
        let requestId = "req-fixture-1"
        let messageId = "msg-fixture-1"
        let vars = ["tenantId": "t", "conversationId": "conv-1", "requestId": requestId, "ratingMessageId": messageId]

        func resolve(_ input: JSONValue?) -> JSONValue? {
            guard let value = input else { return nil }
            switch value {
            case .string(let text):
                if text == "<number>" { return .number(Double(later)) }
                if text == "<nonempty>" { return .string(fixtureText) }
                var out = text
                for (key, replacement) in vars { out = out.replacingOccurrences(of: "{{\(key)}}", with: replacement) }
                return .string(out)
            case .array(let items): return .array(items.map { resolve($0) ?? .null })
            case .object(let map): return .object(map.mapValues { resolve($0) ?? .null })
            default: return value
            }
        }

        let rig = CRig()
        await rig.start()
        await rig.begin("My parcel is late")
        var exercised = 0

        for step in steps {
            if let http = step["http"], http["auth"].string == "visitor" {
                let path = resolve(http["path"]).string ?? ""
                let body = resolve(http["json"]).object
                let expect = resolve(step["expect"]).object
                let status = expect["status"].int ?? 200
                var reply = expect["body"].object
                if status == 200 && path.hasSuffix("/rating") {
                    // The no-op answer in the fixture lists only the score; the real server sends the whole record.
                    reply["requestId"] = reply["requestId"] ?? .string(requestId)
                    reply["closesAt"] = reply["closesAt"] ?? .number(Double(later))
                    reply["ratedAt"] = .number(Double(epoch))
                }
                let answer: Answer = (status, reply.mapValues { fixtureAny($0) }, [:])
                let before = rig.server.requests.count

                if path.hasSuffix("/rating") {
                    rig.server.ratingResponder = { _ in answer }
                    let score = body["score"].int ?? 0
                    do {
                        let result = try await rig.controller.submitRating(score: score, comment: body["comment"].string, requestId: body["requestId"].string)
                        #expect(status == 200, "\(path) succeeded but the fixture expects \(status)")
                        #expect(result.score == reply["score"].int)
                        #expect(result.requestId == reply["requestId"].string ?? requestId)
                        #expect(result.comment == reply["comment"].string)
                        let sent = try #require(rig.server.requests.last)
                        #expect(sent.method == "POST" && sent.path == path)
                        var sentBody = sent.json
                        if body["requestId"] == nil { sentBody["requestId"] = nil } // it names the open card itself
                        #expect(sentBody == body, "the SDK sends the fixture's body")
                    } catch let error as GiovChatError {
                        #expect(status != 200)
                        #expect(error.code == reply["error"].string)
                        if (1...5).contains(score) { #expect(error.status == status) } else { #expect(rig.server.requests.count == before, "an impossible score is refused on the device") }
                    }
                    exercised += 1
                } else if path.contains("/messages/") && path.hasSuffix("/feedback") {
                    let value = body["value"].string ?? ""
                    // "maybe" cannot be expressed with the SDK's types: that refusal is made impossible at compile time.
                    guard value == "none" || GiovAnswerVote(rawValue: value) != nil else { continue }
                    rig.server.feedbackResponder = { _ in answer }
                    let id = String(path.split(separator: "/")[3])
                    do {
                        try await rig.controller.submitAnswerFeedback(messageId: id, vote: GiovAnswerVote(rawValue: value))
                        #expect(status == 200)
                    } catch let error as GiovChatError {
                        #expect(status != 200 && error.code == reply["error"].string && error.status == status)
                    }
                    let sent = try #require(rig.server.requests.last)
                    #expect(sent.path == path && sent.json == body)
                    exercised += 1
                }
                continue
            }
            if let http = step["http"], http["path"].string?.hasSuffix("/rating-request") == true {
                continue // the team's side, outside the visitor API; the next receive step delivers its card
            }
            guard let receive = step["receive"] else { continue }
            let match = resolve(receive["match"]).object
            if match["type"].string == "rating" {
                var frame = match
                frame["conversationId"] = .string("conv-1")
                frame["closesAt"] = frame["closesAt"] ?? .number(Double(later))
                rig.socket.receiveRaw(JSONValue.object(frame).serialized)
                await rig.pump()
                let patched = try #require(ratingBlock(rig, messageId))
                #expect(patched.score == match["score"].int)
                exercised += 1
            } else if match["role"].string == "agent", match["blocks"].array != nil {
                var message = match
                message["content"] = .string(fixtureText)
                message["createdAt"] = .number(Double(epoch + 5))
                var blocks = match["blocks"].array ?? []
                if case .object(var block)? = blocks.first {
                    block["closesAt"] = .number(Double(soon))
                    blocks[0] = .object(block)
                }
                message["blocks"] = .array(blocks)
                rig.socket.receiveRaw(JSONValue.object(message).serialized)
                await rig.pump()
                let pending = try #require(rig.controller.pendingRating)
                #expect(pending.requestId == requestId && pending.messageId == messageId)
                exercised += 1
            }
        }
        // 2 refused/answered ratings of each kind + the vote refusals + the card and the frame.
        #expect(exercised >= 8, "the fixture's visitor steps all ran (\(exercised))")
        await rig.dispose()
    }
}

private func fixtureAny(_ value: JSONValue) -> Any? {
    switch value {
    case .null: return nil
    case .bool(let flag): return flag
    case .number(let number): return number == number.rounded() ? Int(number) : number
    case .string(let text): return text
    case .array(let items): return items.map { fixtureAny($0) }
    case .object(let map): return map.mapValues { fixtureAny($0) }
    }
}

/// The ``GiovChatError`` a call throws; records an issue when it does not throw.
@MainActor
private func expectFailure(_ call: @MainActor () async throws -> Void) async throws -> GiovChatError {
    do {
        try await call()
    } catch let error as GiovChatError {
        return error
    }
    Issue.record("expected the call to fail")
    return GiovChatError.disconnected()
}
