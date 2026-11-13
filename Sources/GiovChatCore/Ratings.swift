import Foundation

// Conversation ratings and thumbs on GiovBot answers (docs/protocol/README.md, "Conversation ratings"). Everything
// here is plain data and pure functions: parsing the `rating` block and frame, patching messages, the card's state
// machine and the mapping of refusals. The controller drives them; the SwiftUI card only draws a
// ``GiovRatingCardState``.

/// The five faces of the rating card, `1` Very bad to `5` Great.
public let giovRatingScores = [1, 2, 3, 4, 5]

/// The longest comment the server takes.
public let giovRatingCommentMaxLength = 1000

/// The longest reason the server takes with a thumbs-down.
public let giovFeedbackReasonMaxLength = 300

/// A visitor's thumb on a GiovBot answer. No vote is `nil`; ``GiovChatController/submitAnswerFeedback(messageId:vote:reason:)``
/// takes `nil` to take a vote back.
public enum GiovAnswerVote: String, Sendable, Equatable {
    case up, down

    /// What tapping `tapped` sends when the current vote is `current`: the same thumb again takes the vote back.
    static func next(current: GiovAnswerVote?, tapped: GiovAnswerVote) -> GiovAnswerVote? {
        current == tapped ? nil : tapped
    }
}

/// A `rating` block of a message: the request to rate the conversation, with the visitor's answer once given.
public struct GiovRatingBlock: Sendable, Equatable {
    public var requestId: String
    /// When the card stops accepting answers or changes, Unix milliseconds. The server decides; the client clock only
    /// picks the read-only look.
    public var closesAt: Int
    /// A small hosted page where the same rating can be given, for clients that cannot draw the card.
    public var url: String?
    /// 1 to 5 once the visitor has answered.
    public var score: Int?
    public var comment: String?
    /// A newer request took this one's place: draw nothing.
    public var replaced: Bool

    public init(requestId: String, closesAt: Int, url: String? = nil, score: Int? = nil, comment: String? = nil, replaced: Bool = false) {
        self.requestId = requestId
        self.closesAt = closesAt
        self.url = url
        self.score = score
        self.comment = comment
        self.replaced = replaced
    }

    /// `hidden` (replaced), `open` (can be answered or changed) or `closed` (read-only) at `now`.
    public func phase(at now: Int) -> GiovRatingPhase {
        if replaced { return .hidden }
        return now < closesAt ? .open : .closed
    }

    /// The block from a message's `blocks` entry; nil when it is not a usable rating block.
    static func fromJSON(_ json: JSONValue?) -> GiovRatingBlock? {
        let map = json.object
        guard map.at("type").string == "rating",
              let requestId = map.at("requestId").nonEmpty,
              let closesAt = map.at("closesAt").int
        else { return nil }
        let score = validRatingScore(map.at("score"))
        return GiovRatingBlock(
            requestId: requestId,
            closesAt: closesAt,
            url: safeHTTPURL(map["url"]),
            score: score,
            comment: score == nil ? nil : map.at("comment").nonEmpty,
            replaced: map.at("state").string == "replaced"
        )
    }
}

/// Where a rating card is in its life.
public enum GiovRatingPhase: String, Sendable, Equatable {
    /// Replaced by a newer request: draw nothing.
    case hidden
    /// Can be answered or changed.
    case open
    /// Read-only.
    case closed
}

func validRatingScore(_ value: JSONValue?) -> Int? {
    guard let score = value.int, (1...5).contains(score), value.number == Double(score) else { return nil }
    return score
}

/// The open request to rate the conversation, for hosts that draw their own UI.
public struct GiovRatingRequest: Sendable, Equatable {
    /// The message that carries the card.
    public var messageId: String
    public var requestId: String
    public var closesAt: Int
    /// The hosted rating page, when the API knows its public origin.
    public var url: String?
    /// The visitor's answer so far.
    public var score: Int?
    public var comment: String?

    public init(messageId: String, requestId: String, closesAt: Int, url: String? = nil, score: Int? = nil, comment: String? = nil) {
        self.messageId = messageId
        self.requestId = requestId
        self.closesAt = closesAt
        self.url = url
        self.score = score
        self.comment = comment
    }

    /// The visitor has answered (the answer may still be changed until ``closesAt``).
    public var isAnswered: Bool { score != nil }
}

/// What the server stored for an answer (`POST /conversations/{id}/rating`).
public struct GiovRatingResult: Sendable, Equatable {
    public var requestId: String
    public var score: Int
    public var comment: String?
    public var closesAt: Int
    /// Unix milliseconds.
    public var ratedAt: Int

    public init(requestId: String, score: Int, comment: String?, closesAt: Int, ratedAt: Int) {
        self.requestId = requestId
        self.score = score
        self.comment = comment
        self.closesAt = closesAt
        self.ratedAt = ratedAt
    }

    static func fromJSON(_ json: [String: JSONValue], now: Int) -> GiovRatingResult? {
        guard let requestId = json.at("requestId").nonEmpty,
              let score = validRatingScore(json["score"]),
              let closesAt = json.at("closesAt").int
        else { return nil }
        return GiovRatingResult(
            requestId: requestId,
            score: score,
            comment: json.at("comment").nonEmpty,
            closesAt: closesAt,
            ratedAt: json.at("ratedAt").int ?? now
        )
    }
}

/// The `rating` socket frame: the card changed (answered or changed on any device).
struct GiovRatingFrame: Sendable, Equatable {
    var requestId: String
    var messageId: String?
    var closesAt: Int
    var score: Int?
    var comment: String?
    /// `state: "replaced"`: a newer card took this one's place; hide it at once.
    var replaced = false

    static func fromJSON(_ json: [String: JSONValue]) -> GiovRatingFrame? {
        guard json.at("type").string == "rating",
              let requestId = json.at("requestId").nonEmpty,
              let closesAt = json.at("closesAt").int
        else { return nil }
        let score = validRatingScore(json["score"])
        return GiovRatingFrame(
            requestId: requestId,
            messageId: json.at("messageId").nonEmpty,
            closesAt: closesAt,
            score: score,
            comment: score == nil ? nil : json.at("comment").nonEmpty,
            replaced: json.at("state").string == "replaced"
        )
    }
}

/// Sets the answer and deadline on the card the frame (or the answer to our own POST) names; other messages stay as
/// they are. A frame without a score means "no answer yet" and clears the card's answer.
func patchRating(_ messages: [GiovMessage], _ frame: GiovRatingFrame) -> [GiovMessage] {
    messages.map { message in
        guard var block = message.rating, block.requestId == frame.requestId else { return message }
        if let id = frame.messageId, id != message.id { return message }
        if frame.replaced {
            block.replaced = true
        } else {
            block.closesAt = frame.closesAt
            block.score = frame.score
            block.comment = frame.comment
        }
        var next = message
        next.rating = block
        return next
    }
}

/// A newer rating card hides every older card the visitor has not answered (one open card per conversation).
func replaceOlderRatings(_ messages: [GiovMessage]) -> [GiovMessage] {
    guard let newest = messages.lastIndex(where: { $0.rating != nil && $0.rating?.replaced == false }) else { return messages }
    var next = messages
    for index in next.indices where index < newest {
        guard var block = next[index].rating, !block.replaced, block.score == nil else { continue }
        block.replaced = true
        next[index].rating = block
    }
    return next
}

extension GiovMessage {
    /// Thumbs go under a finished GiovBot answer, not under a draft and not under the rating card message GiovBot sends.
    public var allowsAnswerFeedback: Bool {
        role == .agent && isBot && !isStreaming && rating == nil
    }
}

/// Sets (or, with `nil`, clears) the visitor's vote on one message.
func applyFeedback(_ messages: [GiovMessage], id: String, vote: GiovAnswerVote?) -> [GiovMessage] {
    messages.map { message in
        guard message.id == id, message.feedback != vote else { return message }
        var next = message
        next.feedback = vote
        return next
    }
}

/// The newest request that is not replaced and not past `closesAt`: the one the visitor can answer or change now.
func openRatingRequest(_ messages: [GiovMessage], now: Int) -> GiovRatingRequest? {
    for message in messages.reversed() {
        guard let block = message.rating, block.phase(at: now) == .open else { continue }
        return GiovRatingRequest(
            messageId: message.id,
            requestId: block.requestId,
            closesAt: block.closesAt,
            url: block.url,
            score: block.score,
            comment: block.comment
        )
    }
    return nil
}

// MARK: - Refusals

/// What a failed rating call means for the card.
public enum GiovRatingFailure: Sendable, Equatable {
    /// `rating_closed`: past `closesAt`. Show the card read-only.
    case closed
    /// `request_replaced`: a newer card took its place. Hide it.
    case replaced
    /// `too_many_changes`: at most 20 changes per card. Show the card read-only.
    case tooManyChanges
    /// `invalid_rating` / `invalid_feedback`: fix the input.
    case invalid
    /// `request_not_found` / `message_not_found`: nothing to answer (any more).
    case notFound
    /// `rate_limited`: try again after the pause.
    case rateLimited(retryAfterSeconds: Int)
    /// The server has no rating routes (an older server): hide the controls.
    case unsupported
    /// Anything else (network, server, session): the answer was not saved, let the visitor try again.
    case retry
}

extension GiovChatError {
    /// This failure as the card sees it; use it to decide what to show after a rating or feedback call failed.
    public var ratingFailure: GiovRatingFailure {
        switch code {
        case "rating_closed": return .closed
        case "request_replaced": return .replaced
        case "too_many_changes": return .tooManyChanges
        case "invalid_rating", "invalid_feedback": return .invalid
        case "request_not_found", "message_not_found": return .notFound
        default: break
        }
        if kind == .rateLimited { return .rateLimited(retryAfterSeconds: retryAfterSeconds ?? 30) }
        if status == 404 { return .unsupported }
        return .retry
    }
}

// MARK: - The card

/// What the rating card draws, worked out from the block, the clock and the visitor's local choices. Pure, so the
/// whole life of a card (pending, answered, changed, closed, replaced) is tested without a UI.
public enum GiovRatingCardState: Sendable, Equatable {
    /// Nothing is drawn (replaced).
    case hidden
    /// The five faces and the comment field. `canCancel` when an earlier answer exists to go back to.
    case form(selected: Int?, comment: String, canCancel: Bool)
    /// "Thanks" with the chosen face and comment; `canChange` while the window is open.
    case answered(score: Int, comment: String?, canChange: Bool)
    /// Read-only without an answer: "This rating request has closed."
    case closed

    /// - Parameters:
    ///   - block: the card's block (with any optimistic answer already applied).
    ///   - now: the clock, Unix milliseconds.
    ///   - editing: the visitor tapped "Change" (or the last send failed) and is choosing again.
    ///   - selected, comment: the visitor's unsent choice in the form.
    ///   - lock: a refusal that made the card read-only or hidden since it was drawn.
    public static func make(
        block: GiovRatingBlock,
        now: Int,
        editing: Bool = false,
        selected: Int? = nil,
        comment: String = "",
        lock: GiovRatingFailure? = nil
    ) -> GiovRatingCardState {
        if lock == .replaced || block.replaced { return .hidden }
        let locked = lock == .closed || lock == .tooManyChanges
        let open = block.phase(at: now) == .open && !locked
        if let score = block.score, !editing || !open {
            return .answered(score: score, comment: block.comment, canChange: open)
        }
        if !open { return .closed }
        return .form(selected: selected, comment: comment, canCancel: block.score != nil)
    }

    /// The face to focus after an arrow key (or VoiceOver adjustment): wraps around.
    public static func step(from current: Int?, by delta: Int) -> Int {
        ((current ?? 1) - 1 + delta + 5) % 5 + 1
    }

    /// `comment` cut to the server's limit (UTF-16 units, as the server counts), never splitting a character.
    public static func clampComment(_ text: String) -> String {
        guard text.utf16.count > giovRatingCommentMaxLength else { return text }
        var units = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            units += text.utf16.distance(from: index, to: next)
            if units > giovRatingCommentMaxLength { break }
            end = next
        }
        return String(text[..<end])
    }

    /// The reason cut to the server's limit.
    public static func clampReason(_ text: String) -> String {
        guard text.utf16.count > giovFeedbackReasonMaxLength else { return text }
        var units = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            units += text.utf16.distance(from: index, to: next)
            if units > giovFeedbackReasonMaxLength { break }
            end = next
        }
        return String(text[..<end])
    }
}

/// The text of the rating card and the thumbs, in the same five languages as ``GiovChatStrings``.
public struct GiovRatingStrings: Sendable {
    /// The card's accessible name.
    public var title: String
    /// The five faces' labels (and accessibility labels), `1` first.
    public var faces: [String]
    /// Accessible name of the group of faces.
    public var yourRating: String
    public var commentPlaceholder: String
    public var send: String
    public var cancel: String
    public var change: String
    /// "Thanks" next to the chosen face; takes the face's label.
    public var thanks: @Sendable (String) -> String
    public var closed: String
    /// Shown when an answer could not be saved.
    public var couldNotSend: String
    public var goodAnswer: String
    public var badAnswer: String
    /// Accessible name of the group of thumbs.
    public var rateAnswer: String
    public var reasonPlaceholder: String
    public var skip: String
    public var couldNotSave: String

    public init(
        title: String,
        faces: [String],
        yourRating: String,
        commentPlaceholder: String,
        send: String,
        cancel: String,
        change: String,
        thanks: @escaping @Sendable (String) -> String,
        closed: String,
        couldNotSend: String,
        goodAnswer: String,
        badAnswer: String,
        rateAnswer: String,
        reasonPlaceholder: String,
        skip: String,
        couldNotSave: String
    ) {
        self.title = title
        self.faces = faces.count == 5 ? faces : ["Very bad", "Bad", "Okay", "Good", "Great"]
        self.yourRating = yourRating
        self.commentPlaceholder = commentPlaceholder
        self.send = send
        self.cancel = cancel
        self.change = change
        self.thanks = thanks
        self.closed = closed
        self.couldNotSend = couldNotSend
        self.goodAnswer = goodAnswer
        self.badAnswer = badAnswer
        self.rateAnswer = rateAnswer
        self.reasonPlaceholder = reasonPlaceholder
        self.skip = skip
        self.couldNotSave = couldNotSave
    }

    /// The label of face `score` (1 to 5).
    public func face(_ score: Int) -> String {
        faces.indices.contains(score - 1) ? faces[score - 1] : ""
    }

    /// The sentence for a failed answer.
    public func describe(_ failure: GiovRatingFailure) -> String? {
        switch failure {
        case .closed, .tooManyChanges, .replaced, .unsupported, .notFound: return nil
        case .invalid, .rateLimited, .retry: return couldNotSend
        }
    }

    public static let en = GiovRatingStrings(
        title: "Rate this conversation",
        faces: ["Very bad", "Bad", "Okay", "Good", "Great"],
        yourRating: "Your rating",
        commentPlaceholder: "Add a comment (optional)",
        send: "Send",
        cancel: "Cancel",
        change: "Change",
        thanks: { "Thanks · \($0)" },
        closed: "This rating request has closed.",
        couldNotSend: "Couldn't send. Please try again.",
        goodAnswer: "Good answer",
        badAnswer: "Bad answer",
        rateAnswer: "Rate this answer",
        reasonPlaceholder: "What went wrong? (optional)",
        skip: "Skip",
        couldNotSave: "Couldn't save"
    )

    public static let fr = GiovRatingStrings(
        title: "Évaluer cette conversation",
        faces: ["Très mauvais", "Mauvais", "Moyen", "Bien", "Excellent"],
        yourRating: "Votre note",
        commentPlaceholder: "Ajouter un commentaire (facultatif)",
        send: "Envoyer",
        cancel: "Annuler",
        change: "Modifier",
        thanks: { "Merci · \($0)" },
        closed: "Cette demande d’évaluation est terminée.",
        couldNotSend: "Envoi impossible. Réessayez.",
        goodAnswer: "Bonne réponse",
        badAnswer: "Mauvaise réponse",
        rateAnswer: "Évaluer cette réponse",
        reasonPlaceholder: "Qu’est-ce qui n’allait pas ? (facultatif)",
        skip: "Passer",
        couldNotSave: "Enregistrement impossible"
    )

    public static let es = GiovRatingStrings(
        title: "Valora esta conversación",
        faces: ["Muy mal", "Mal", "Regular", "Bien", "Excelente"],
        yourRating: "Tu valoración",
        commentPlaceholder: "Añade un comentario (opcional)",
        send: "Enviar",
        cancel: "Cancelar",
        change: "Cambiar",
        thanks: { "Gracias · \($0)" },
        closed: "Esta solicitud de valoración ha terminado.",
        couldNotSend: "No se pudo enviar. Inténtalo de nuevo.",
        goodAnswer: "Buena respuesta",
        badAnswer: "Mala respuesta",
        rateAnswer: "Valora esta respuesta",
        reasonPlaceholder: "¿Qué salió mal? (opcional)",
        skip: "Omitir",
        couldNotSave: "No se pudo guardar"
    )

    public static let pt = GiovRatingStrings(
        title: "Avalie esta conversa",
        faces: ["Muito ruim", "Ruim", "Regular", "Bom", "Ótimo"],
        yourRating: "Sua avaliação",
        commentPlaceholder: "Adicione um comentário (opcional)",
        send: "Enviar",
        cancel: "Cancelar",
        change: "Alterar",
        thanks: { "Obrigado · \($0)" },
        closed: "Este pedido de avaliação foi encerrado.",
        couldNotSend: "Não foi possível enviar. Tente novamente.",
        goodAnswer: "Boa resposta",
        badAnswer: "Resposta ruim",
        rateAnswer: "Avalie esta resposta",
        reasonPlaceholder: "O que deu errado? (opcional)",
        skip: "Pular",
        couldNotSave: "Não foi possível salvar"
    )

    public static let de = GiovRatingStrings(
        title: "Diese Unterhaltung bewerten",
        faces: ["Sehr schlecht", "Schlecht", "Okay", "Gut", "Sehr gut"],
        yourRating: "Deine Bewertung",
        commentPlaceholder: "Kommentar hinzufügen (optional)",
        send: "Senden",
        cancel: "Abbrechen",
        change: "Ändern",
        thanks: { "Danke · \($0)" },
        closed: "Diese Bewertungsanfrage ist beendet.",
        couldNotSend: "Senden fehlgeschlagen. Bitte versuche es erneut.",
        goodAnswer: "Gute Antwort",
        badAnswer: "Schlechte Antwort",
        rateAnswer: "Diese Antwort bewerten",
        reasonPlaceholder: "Was ist schiefgelaufen? (optional)",
        skip: "Überspringen",
        couldNotSave: "Speichern fehlgeschlagen"
    )

    static let all: [String: GiovRatingStrings] = ["en": .en, "fr": .fr, "es": .es, "pt": .pt, "de": .de]
}
