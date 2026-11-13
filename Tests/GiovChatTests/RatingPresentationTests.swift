import Foundation
@testable import GiovChat
import GiovChatCore
import Testing

private let block = GiovRatingBlock(requestId: "r", closesAt: 1000)

@Suite struct RatingCardModelTests {
    @Test func pendingToAnsweredToChangedToClosed() {
        var model = GiovRatingCardModel()
        #expect(model.card(block: block, now: 0) == .form(selected: nil, comment: "", canCancel: false))
        #expect(model.beginSend() == nil, "nothing picked yet")

        model.select(4)
        model.setComment("  Quick answer ")
        #expect(model.card(block: block, now: 0) == .form(selected: 4, comment: "  Quick answer ", canCancel: false))
        let choice = model.beginSend()
        #expect(choice?.score == 4 && choice?.comment == "Quick answer", "the comment is trimmed")
        #expect(model.sending)
        #expect(model.beginSend() == nil, "one answer at a time")
        model.select(1)
        #expect(model.selected == 4, "the faces are off while sending")

        // The controller has applied the answer to the block; the server accepts.
        var answered = block
        answered.score = 4
        answered.comment = "Quick answer"
        model.sent()
        #expect(model.card(block: answered, now: 0) == .answered(score: 4, comment: "Quick answer", canChange: true))

        // Change: the form comes back with the earlier answer, and Cancel returns to it.
        model.beginEditing(from: answered)
        #expect(model.card(block: answered, now: 0) == .form(selected: 4, comment: "Quick answer", canCancel: true))
        model.cancelEditing()
        #expect(model.card(block: answered, now: 0) == .answered(score: 4, comment: "Quick answer", canChange: true))
        model.beginEditing(from: answered)
        model.select(5)
        #expect(model.beginSend()?.score == 5)
        model.sent()

        // Past closesAt it is read-only, and "Change" is gone.
        #expect(model.card(block: answered, now: 1000) == .answered(score: 4, comment: "Quick answer", canChange: false))
    }

    @Test func aBlankCommentIsLeftOut() {
        var model = GiovRatingCardModel()
        model.select(3)
        model.setComment("   ")
        #expect(model.beginSend()?.comment == nil)
    }

    @Test func aFailedSendComesBackAsTheFormWithTheChoiceKept() {
        var model = GiovRatingCardModel()
        model.select(2)
        model.setComment("slow")
        _ = model.beginSend()
        model.failed(.retry)
        #expect(!model.sending && model.editing)
        #expect(model.failure == .retry)
        #expect(model.card(block: block, now: 0) == .form(selected: 2, comment: "slow", canCancel: false))
        _ = model.beginSend()
        #expect(model.failure == nil, "a new try clears the message")
        model.failed(.rateLimited(retryAfterSeconds: 12))
        #expect(model.failure == .rateLimited(retryAfterSeconds: 12))
        model.failed(.invalid)
        #expect(model.editing)
    }

    @Test func closedAndReplacedRefusalsLockTheCard() {
        var closed = GiovRatingCardModel()
        closed.select(2)
        _ = closed.beginSend()
        closed.failed(.closed)
        #expect(closed.card(block: block, now: 0) == .closed)

        var many = GiovRatingCardModel()
        many.select(2)
        _ = many.beginSend()
        many.failed(.tooManyChanges)
        var answered = block
        answered.score = 3
        #expect(many.card(block: answered, now: 0) == .answered(score: 3, comment: nil, canChange: false))

        var replaced = GiovRatingCardModel()
        replaced.select(2)
        _ = replaced.beginSend()
        replaced.failed(.replaced)
        #expect(replaced.card(block: block, now: 0) == .hidden)

        var gone = GiovRatingCardModel()
        _ = gone.beginSend()
        gone.failed(.unsupported)
        #expect(gone.card(block: block, now: 0) == .closed)
    }

    @Test func theCommentIsClamped() {
        var model = GiovRatingCardModel()
        model.setComment(String(repeating: "x", count: 1500))
        #expect(model.comment.utf16.count == 1000)
    }

    @Test func faceAccessibilityNamesTheFaceAndSelection() {
        let strings = GiovChatStrings.en.rating
        #expect(giovFaceAccessibility(1, selected: 1, strings: strings) == (label: "Very bad", selected: true))
        #expect(giovFaceAccessibility(5, selected: 1, strings: strings) == (label: "Great", selected: false))
        #expect(giovFaceAccessibility(3, selected: nil, strings: GiovChatStrings.fr.rating).label == "Moyen")
    }
}

@Suite struct FeedbackModelTests {
    @Test func tappingTheActiveThumbTakesTheVoteBack() {
        var model = GiovFeedbackModel()
        #expect(model.tap(.up, current: nil) == .up)
        #expect(!model.asking)
        #expect(model.tap(.up, current: .up) == nil)
        #expect(model.tap(.down, current: .up) == .down)
        #expect(model.asking, "a thumbs-down offers a reason")
        #expect(model.tap(.down, current: .down) == nil)
        #expect(!model.asking)
    }

    @Test func theReasonIsOptionalTrimmedAndClamped() {
        var model = GiovFeedbackModel()
        _ = model.tap(.down, current: nil)
        model.setReason("  too slow ")
        #expect(model.submitReason() == "too slow")
        #expect(!model.asking)

        _ = model.tap(.down, current: nil)
        model.setReason("   ")
        #expect(model.submitReason() == nil, "nothing to send")

        _ = model.tap(.down, current: nil)
        model.skip()
        #expect(!model.asking)

        _ = model.tap(.down, current: nil)
        model.setReason(String(repeating: "r", count: 400))
        #expect(model.reason.utf16.count == 300)
        model.fail()
        #expect(model.failed && !model.asking)
        _ = model.tap(.up, current: nil)
        #expect(!model.failed, "a new tap clears the failure")
    }

    @Test func thumbsAndCardsFollowTheHostAndTheServer() {
        let answer = GiovMessage(id: "b", role: .agent, content: "x", createdAt: 1, isBot: true)
        let card = GiovMessage(id: "c", role: .agent, content: "x", createdAt: 1, rating: block)
        var state = GiovChatUiState()
        #expect(giovShowsThumbs(answer, state: state))
        #expect(!giovShowsThumbs(card, state: state))
        #expect(giovShowsRatingCard(card, state: state))
        #expect(!giovShowsRatingCard(answer, state: state))

        state.showsAnswerFeedback = false
        state.showsRatingCard = false
        #expect(!giovShowsThumbs(answer, state: state) && !giovShowsRatingCard(card, state: state))

        state = GiovChatUiState()
        state.feedbackAvailable = false
        state.ratingsAvailable = false
        #expect(!giovShowsThumbs(answer, state: state) && !giovShowsRatingCard(card, state: state))

        var replaced = card
        replaced.rating?.replaced = true
        #expect(!giovShowsRatingCard(replaced, state: GiovChatUiState()), "a replaced card draws nothing")
    }
}

@Suite struct ClosedBarTests {
    @Test func theBarReplacesTheComposerOnlyOnAClosedConversation() {
        var state = GiovChatUiState()
        #expect(GiovClosedBarModel(state, strings: .en) == nil)
        state.conversationClosed = true
        let model = GiovClosedBarModel(state, strings: .en)
        #expect(model?.button == "Start a new conversation")
        #expect(model?.notice == GiovChatStrings.en.conversationEnded)
        #expect(GiovClosedBarModel(state, strings: .fr)?.button == "Démarrer une nouvelle conversation")
    }

    @Test func everyLanguageHasTheButton() {
        for (code, strings) in GiovChatStrings.all {
            #expect(!strings.startNewConversation.trimmingCharacters(in: .whitespaces).isEmpty, "\(code)")
        }
        #expect(GiovChatStrings.en.withOverrides(startNewConversation: "New chat").startNewConversation == "New chat")
    }
}
