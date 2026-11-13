import Foundation
import GiovChatCore

// The rating card's local state and the thumbs' rules, without any UI framework, so the whole life of a card is
// tested on every platform. The SwiftUI views (Views/RatingViews.swift) only draw these values.

/// What the visitor has done to one rating card on this device: the unsent choice, "Change", the answer on its way
/// and a refusal. ``card(block:now:)`` turns it into what is drawn.
struct GiovRatingCardModel: Sendable, Equatable {
    var selected: Int?
    var comment = ""
    var editing = false
    /// An answer is on its way (the card already shows it; the faces and Send are off).
    var sending = false
    /// Read-only or hidden after a refusal.
    var lock: GiovRatingFailure?
    /// The failure to show above Send (retry), if any.
    var failure: GiovRatingFailure?

    init() {}

    func card(block: GiovRatingBlock, now: Int) -> GiovRatingCardState {
        GiovRatingCardState.make(block: block, now: now, editing: editing, selected: selected, comment: comment, lock: lock)
    }

    /// Picks a face (ignored while sending).
    mutating func select(_ score: Int) {
        guard !sending, giovRatingScores.contains(score) else { return }
        selected = score
    }

    mutating func setComment(_ text: String) {
        comment = GiovRatingCardState.clampComment(text)
    }

    /// "Change": back to the form with the earlier answer filled in.
    mutating func beginEditing(from block: GiovRatingBlock) {
        guard !sending else { return }
        selected = block.score
        comment = block.comment ?? ""
        failure = nil
        editing = true
    }

    /// "Cancel": back to the answer.
    mutating func cancelEditing() {
        guard !sending else { return }
        editing = false
        failure = nil
    }

    /// Send: the choice to submit, or nil when nothing is picked or an answer is already on its way.
    mutating func beginSend() -> (score: Int, comment: String?)? {
        guard !sending, let score = selected else { return nil }
        sending = true
        failure = nil
        editing = false
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return (score, text.isEmpty ? nil : text)
    }

    /// The server saved the answer.
    mutating func sent() {
        sending = false
        editing = false
        failure = nil
        selected = nil
        comment = ""
    }

    /// The answer was refused: read-only or hidden for `closed`, `replaced` and `tooManyChanges`; otherwise the form
    /// comes back with the choice kept and a sentence to show.
    mutating func failed(_ reason: GiovRatingFailure) {
        sending = false
        switch reason {
        case .closed, .replaced, .tooManyChanges, .notFound, .unsupported:
            lock = reason == .notFound || reason == .unsupported ? .closed : reason
            editing = false
            failure = nil
        case .invalid, .rateLimited, .retry:
            editing = true
            failure = reason
        }
    }
}

/// What tapping a thumb does and what the reason prompt shows.
struct GiovFeedbackModel: Sendable, Equatable {
    var asking = false
    var reason = ""
    var failed = false

    init() {}

    /// Tapping `tapped` while the vote is `current`: the vote to send (`nil` takes it back). A thumbs-down opens the
    /// optional reason prompt.
    mutating func tap(_ tapped: GiovAnswerVote, current: GiovAnswerVote?) -> GiovAnswerVote? {
        let next: GiovAnswerVote? = current == tapped ? nil : tapped
        failed = false
        reason = ""
        asking = next == .down
        return next
    }

    mutating func setReason(_ text: String) {
        reason = GiovRatingCardState.clampReason(text)
    }

    /// Send on the reason prompt: the reason to send, or nil when it is blank (nothing to send).
    mutating func submitReason() -> String? {
        asking = false
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    mutating func skip() {
        asking = false
    }

    mutating func fail() {
        asking = false
        failed = true
    }
}

/// Whether thumbs are drawn under `message`: a finished GiovBot answer (not the rating card message), the host did
/// not turn them off and the server has the route.
func giovShowsThumbs(_ message: GiovMessage, state: GiovChatUiState) -> Bool {
    state.showsAnswerFeedback && state.feedbackAvailable && message.allowsAnswerFeedback
}

/// Whether the card of `message` is drawn inline: the host did not turn the built-in card off, the server has the
/// route and the card is not replaced.
func giovShowsRatingCard(_ message: GiovMessage, state: GiovChatUiState) -> Bool {
    guard let block = message.rating else { return false }
    return state.showsRatingCard && state.ratingsAvailable && !block.replaced
}

/// The accessibility value of one face: its label, and whether it is the selected one.
func giovFaceAccessibility(_ score: Int, selected: Int?, strings: GiovRatingStrings) -> (label: String, selected: Bool) {
    (strings.face(score), selected == score)
}
