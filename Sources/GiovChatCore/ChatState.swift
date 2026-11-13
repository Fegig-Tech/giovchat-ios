import Foundation

/// Where the chat is.
///
/// `ready`: the chat can be used but no conversation exists yet. Per the visitor protocol a native client starts one
/// when the visitor sends the first message (or submits the pre-chat form), so opening the screen never creates an
/// empty conversation. `idle`: hidden with nothing to resume.
public enum GiovChatPhase: String, Sendable, Equatable {
    case idle, loading, preChat, ready, connecting, active, error
}

public enum GiovConnectionStatus: String, Sendable, Equatable {
    case connecting, connected, disconnected
}

/// A file being uploaded; ``progress`` is 0 to 1.
public struct GiovUploadProgress: Sendable, Equatable {
    public var name: String
    public var progress: Double

    public init(name: String, progress: Double) {
        self.name = name
        self.progress = progress
    }
}

/// Everything the chat screen draws, as one immutable snapshot. Read ``GiovChatController/state``; a new value is
/// published after every change.
public struct GiovChatUiState: Sendable, Equatable {
    public var phase: GiovChatPhase = .loading
    /// Nil until the configuration has loaded.
    public var config: GiovWidgetConfig?
    /// What to draw, oldest first: saved messages, sending ones, and streaming drafts. Use ``GiovMessage/key`` as
    /// the list identity.
    public var messages: [GiovMessage] = []
    /// Who the header shows (person, bot, team); nil until the configuration has loaded.
    public var header: GiovHeaderIdentity?
    /// The teammate who has the conversation, once known.
    public var agentName: String?
    public var agentAvatar: String?
    /// The agent side is typing. When ``agentTypingIsBot`` is true, show the bot's indicator.
    public var agentTyping = false
    public var agentTypingIsBot: Bool?
    /// Replies the visitor has not seen because the chat was not visible; 0 while visible.
    public var unreadCount = 0
    /// The last failure worth showing; use ``GiovChatStrings/describeError(_:)``. Cleared when sending resumes.
    public var error: GiovChatError?
    /// Files are uploading before their message is queued.
    public var sending = false
    public var uploads: [GiovUploadProgress] = []
    /// Pre-chat fields still to ask for (when ``phase`` is ``GiovChatPhase/preChat``).
    public var requiredFields = GiovRequestUserInfo()
    /// A conversation exists (so attachments can be uploaded).
    public var hasConversation = false
    public var connectionStatus: GiovConnectionStatus = .disconnected
    /// The connection dropped (or the first one failed) and is being restored with backoff; show
    /// ``GiovChatStrings/reconnecting``.
    public var reconnecting = false
    public var visible = true
    /// The conversation id, once started.
    public var conversationId: String?
    /// The open request to rate the conversation (not replaced, before its `closesAt`); `score` is set once answered.
    public var ratingRequest: GiovRatingRequest?
    /// False once the server showed it has no rating route (an older server): hide the rating card.
    public var ratingsAvailable = true
    /// False once the server showed it has no answer-feedback route: hide the thumbs.
    public var feedbackAvailable = true
    /// The built-in chat UI draws the rating card (the host turned it off with `showsRatingCard: false` otherwise).
    public var showsRatingCard = true
    /// The built-in chat UI draws thumbs under GiovBot answers.
    public var showsAnswerFeedback = true
    /// The host asked for the rating sheet with ``GiovChatController/presentRating()``.
    public var ratingSheetPresented = false
    /// The team closed the conversation: it is shown read-only. ``GiovChatController/startNewConversation()`` leaves it.
    public var conversationClosed = false

    public init(visible: Bool = true) {
        self.visible = visible
    }

    public var isConnected: Bool { connectionStatus == .connected }
}

/// A reply being written.
struct GiovDraft: Sendable, Equatable {
    let content: String
    let createdAt: Int
}

private let emailPattern = Pattern("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+\\z")

/// Contact fields the workspace requires and the host has not supplied (or that are malformed).
func missingContactFields(_ fields: GiovRequestUserInfo, contact: GiovContact) -> GiovRequestUserInfo {
    func missing(_ required: Bool, _ value: String?, email: Bool = false) -> Bool {
        guard required else { return false }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || (email && !emailPattern.matches(text))
    }
    return GiovRequestUserInfo(
        email: missing(fields.email, contact.email, email: true),
        phone: missing(fields.phone, contact.phone),
        firstName: missing(fields.firstName, contact.firstName),
        lastName: missing(fields.lastName, contact.lastName)
    )
}

private func byTime(_ a: GiovMessage, _ b: GiovMessage) -> Bool {
    a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
}

/// By server id; a copy without a local key keeps the one it was shown under, so the bubble is not redrawn. Sorted
/// by creation time.
func mergeMessages(_ current: [GiovMessage], _ incoming: [GiovMessage]) -> [GiovMessage] {
    var order: [String] = []
    var byId: [String: GiovMessage] = [:]
    for message in current {
        if byId[message.id] == nil { order.append(message.id) }
        byId[message.id] = message
    }
    for message in incoming {
        var next = message
        if let existing = byId[message.id], let key = existing.clientMessageId, message.clientMessageId == nil {
            next.clientMessageId = key
        }
        if byId[message.id] == nil { order.append(message.id) }
        byId[message.id] = next
    }
    return order.compactMap { byId[$0] }.sorted(by: byTime)
}

/// What the visitor sees: saved messages, then what is still sending, then replies being written. `describe`
/// supplies names and types for files sent from this device.
func displayMessages(
    saved: [GiovMessage],
    pending: [OutboxEntry],
    drafts: [(streamId: String, draft: GiovDraft)],
    describe: ((String) -> GiovAttachment)? = nil
) -> [GiovMessage] {
    func known(_ url: String) -> GiovAttachment { describe?(url) ?? GiovAttachment(url: url) }
    let shown = Set(saved.compactMap(\.clientMessageId))
    var list: [GiovMessage] = []
    for message in saved {
        if message.attachments.isEmpty {
            list.append(message)
        } else {
            var copy = message
            copy.attachments = message.attachments.map { attachment in
                let local = known(attachment.url)
                return GiovAttachment(
                    url: attachment.url,
                    filename: attachment.filename.isEmpty ? local.filename : attachment.filename,
                    preview: attachment.preview ?? local.preview,
                    contentType: attachment.contentType ?? local.contentType
                )
            }
            list.append(copy)
        }
    }
    for entry in pending where !shown.contains(entry.clientMessageId) {
        list.append(GiovMessage(
            id: entry.clientMessageId,
            role: .visitor,
            content: entry.content,
            createdAt: entry.createdAt,
            attachments: entry.attachments.map(known),
            delivery: entry.state == .failed ? .failed : .sending,
            clientMessageId: entry.clientMessageId
        ))
    }
    for (streamId, draft) in drafts {
        let key = "stream:\(streamId)"
        if shown.contains(key) || draft.content.isEmpty { continue }
        list.append(GiovMessage(
            id: key,
            role: .agent,
            content: draft.content,
            createdAt: draft.createdAt,
            isBot: true,
            isAutomated: true,
            clientMessageId: key,
            streamId: streamId,
            isStreaming: true
        ))
    }
    // A stable sort keeps saved, sending and draft order for equal times, as in the other SDKs.
    return list.enumerated().sorted { lhs, rhs in
        if byTime(lhs.element, rhs.element) { return true }
        if byTime(rhs.element, lhs.element) { return false }
        return lhs.offset < rhs.offset
    }.map(\.element)
}
