import Foundation
import GiovChatCore

// What the chat screen shows, worked out from the controller's state without any UI framework, so it can be tested
// on every platform. The SwiftUI views only draw these values.

/// The privacy page the header menu links to when the workspace has not set its own (the web widget's default).
let giovDefaultPrivacyPolicyURL = URL(string: "https://giovchat.app/privacy")!

/// The workspace's privacy policy (`privacyPolicyUrl`), else Giov's, as in the web widget's menu.
func giovPrivacyPolicyURL(_ config: GiovWidgetConfig?) -> URL {
    config?.privacyPolicyURL.flatMap { giovIsHTTPURL($0) ? URL(string: $0) : nil } ?? giovDefaultPrivacyPolicyURL
}

/// The line above the messages: the failure to show, else "Reconnecting" while a lost connection is restored.
func giovBannerText(_ state: GiovChatUiState, strings: GiovChatStrings) -> String? {
    if let error = state.error { return strings.describeError(error) }
    return state.reconnecting ? strings.reconnecting : nil
}

/// Decides what VoiceOver announces as replies arrive: every finished message from the team or GiovBot that was not
/// on screen before. The first update only records what is already there, a batch of more than two (a history load)
/// is recorded silently, and a reply that is still streaming is announced once it is saved.
struct GiovMessageAnnouncer: Sendable, Equatable {
    private var seen: Set<String> = []
    private var primed = false

    init() {}

    /// The sentence to announce for what arrived since the last call, or nil.
    mutating func update(_ state: GiovChatUiState, strings: GiovChatStrings) -> String? {
        var fresh: [String] = []
        for message in state.messages where message.role == .agent && !message.isStreaming {
            guard seen.insert(message.key).inserted else { continue }
            if primed { fresh.append(Self.sentence(message, state: state, strings: strings)) }
        }
        primed = true
        // Live replies arrive one or two at a time; more at once is a history load or a catch-up after a reconnect,
        // which is not read out.
        return fresh.isEmpty || fresh.count > 2 ? nil : fresh.joined(separator: ". ")
    }

    private static func sentence(_ message: GiovMessage, state: GiovChatUiState, strings: GiovChatStrings) -> String {
        let sender = giovMessageSenderLabel(message, strings: strings, botName: giovBotName(state), agentName: state.agentName)
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? message.attachments.map { giovAttachmentName($0, strings: strings) }.joined(separator: ", ") : text
        return body.isEmpty ? sender : "\(sender): \(body)"
    }
}

/// Where "Powered by GiovChat" leads.
let giovBrandingURL = URL(string: "https://giovchat.app/?utm_source=ios_widget&utm_medium=powered_by")!

/// The longest message the server takes, in characters.
let giovMaxMessageCharacters = 2000

/// The main area of the screen for a phase.
enum GiovScreenContent: Sendable, Equatable {
    /// Loading (or hidden with nothing to resume): the skeleton.
    case skeleton
    /// A failure that needs a fresh start, with its sentence and "Try again".
    case error(String)
    /// The pre-chat form.
    case preChat
    /// Greeting, messages and composer (ready, connecting, active).
    case conversation

    init(_ state: GiovChatUiState, strings: GiovChatStrings) {
        switch state.phase {
        case .loading, .idle: self = .skeleton
        case .error: self = .error(state.error.map { strings.describeError($0) } ?? strings.unavailable)
        case .preChat: self = .preChat
        case .ready, .connecting, .active: self = .conversation
        }
    }
}

/// The header: who is answering, a status line and what the avatar shows.
struct GiovHeaderModel: Sendable, Equatable {
    var title: String
    var subtitle: String?
    var kind: GiovHeaderKind?
    /// An http(s) photo; nil shows the GiovBot mark (bot) or ``initial``.
    var avatarURL: String?
    /// The first letter of the title, upper-cased; empty for a blank title.
    var initial: String

    init(_ state: GiovChatUiState, strings: GiovChatStrings) {
        let identity = state.header
        title = identity?.title ?? state.config?.title ?? "Chat"
        kind = identity?.kind
        avatarURL = identity?.avatar.flatMap { giovIsHTTPURL($0) ? $0 : nil }
        switch state.phase {
        case .active, .ready: subtitle = identity?.status(strings)
        case .connecting: subtitle = strings.connecting
        default: subtitle = nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        initial = trimmed.first.map { String($0).uppercased() } ?? ""
    }
}

/// The bot's name for labels and the typing indicator: the configured one, else the header's while the bot answers.
func giovBotName(_ state: GiovChatUiState) -> String? {
    if let name = state.config?.botName { return name }
    if let header = state.header, header.kind == .bot { return header.title }
    return nil
}

/// What VoiceOver says for the typing indicator.
func giovTypingLabel(isBot: Bool?, botName: String?, strings: GiovChatStrings) -> String {
    guard isBot == true else { return strings.teamTyping }
    let name = botName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return strings.botTyping(name.isEmpty ? "GiovBot" : name)
}

/// A message's time, e.g. "14:05" or "2:05 PM", in the device's format.
func giovTimeLabel(_ createdAt: Int, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
    let date = Date(timeIntervalSince1970: Double(createdAt) / 1000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = timeZone
    let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
    return style.format(date)
}

/// One message bubble, ready to draw.
struct GiovBubbleModel: Sendable, Equatable {
    /// The list identity (``GiovMessage/key``): stable while a message is confirmed or a draft is saved.
    var key: String
    var isVisitor: Bool
    /// A GiovBot reply: the bot mark sits beside it.
    var showsBotMark: Bool
    var senderLabel: String
    /// Chat markdown; empty for an attachment-only message.
    var content: String
    var attachments: [GiovAttachment]
    /// "Sending…" or the time; nil while a reply streams in.
    var footer: String?
    /// The message is on its way (drawn a little faded).
    var isSending: Bool
    /// The text under a failed message ("Not sent · Tap to retry"); nil unless it failed.
    var failureText: String?
    /// The id to retry or discard a failed message with.
    var clientMessageId: String?

    init(_ message: GiovMessage, strings: GiovChatStrings, botName: String?, agentName: String?, time: (Int) -> String) {
        key = message.key
        isVisitor = message.role == .visitor
        showsBotMark = message.role == .agent && message.isBot
        senderLabel = giovMessageSenderLabel(message, strings: strings, botName: botName, agentName: agentName)
        content = message.content
        attachments = message.attachments
        isSending = isVisitor && message.delivery == .sending
        if message.isStreaming {
            footer = nil
        } else {
            footer = isSending ? strings.sending : time(message.createdAt)
        }
        clientMessageId = message.clientMessageId
        if isVisitor && message.delivery == .failed {
            failureText = clientMessageId != nil ? "\(strings.notSent) · \(strings.tapToRetry)" : strings.notSent
        } else {
            failureText = nil
        }
    }
}

/// What replaces the composer once the team closed the conversation: the notice and the "Start a new conversation"
/// button; nil while the conversation is open.
struct GiovClosedBarModel: Sendable, Equatable {
    var notice: String
    var button: String

    init?(_ state: GiovChatUiState, strings: GiovChatStrings) {
        guard state.conversationClosed else { return nil }
        notice = strings.conversationEnded
        button = strings.startNewConversation
    }
}

/// When the composer and its buttons work.
enum GiovComposerRules {
    /// The visitor can write in these phases.
    static func composing(_ phase: GiovChatPhase) -> Bool {
        phase == .ready || phase == .connecting || phase == .active
    }

    /// The text field stays editable while files upload; only Send waits (``canSend(phase:sending:busy:text:fileCount:)``).
    /// Disabling a focused field would also close the keyboard.
    static func textEditable(_ phase: GiovChatPhase) -> Bool {
        composing(phase)
    }

    static func canSend(phase: GiovChatPhase, sending: Bool, busy: Bool, text: String, fileCount: Int) -> Bool {
        composing(phase) && !sending && !busy
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fileCount > 0)
    }

    /// The attach button shows once a conversation exists (uploads need one) and the policy allows any type.
    static func canAttach(_ state: GiovChatUiState) -> Bool {
        guard state.hasConversation, let policy = state.config?.attachmentPolicy else { return false }
        return policy.enabled && !policy.allowedTypes.isEmpty
    }

    static func attachEnabled(sending: Bool, fileCount: Int) -> Bool {
        !sending && fileCount < GiovAttachmentLimits.maxFiles
    }

    /// `text` cut to the server's limit. The server (and the outbox) count UTF-16 code units, as JavaScript does, so
    /// an emoji counts as two; the cut never splits a character.
    static func clamp(_ text: String) -> String {
        guard text.utf16.count > giovMaxMessageCharacters else { return text }
        var units = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            units += text.utf16.distance(from: index, to: next)
            if units > giovMaxMessageCharacters { break }
            end = next
        }
        return String(text[..<end])
    }
}

/// Which pickers the attach button offers for a policy.
struct GiovPickerOptions: Sendable, Equatable {
    /// The photo library: some image type is allowed.
    var photos: Bool
    /// The Files app: anything allowed.
    var files: Bool
    /// The photo library's selection limit.
    var maxPhotos: Int
    /// MIME types the Files picker offers.
    var allowedTypes: [String]

    init(policy: GiovAttachmentPolicy, alreadyAttached: Int) {
        let allowed = policy.enabled ? policy.allowedTypes : []
        allowedTypes = allowed
        photos = allowed.contains { giovPhotoTypes.contains($0) }
        files = !allowed.isEmpty
        maxPhotos = max(1, GiovAttachmentLimits.maxFiles - alreadyAttached)
    }
}

/// Image types a photo can be sent as.
let giovPhotoTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

/// The text of a picked-file chip: upload progress while it goes, else the file name.
func giovChipText(index: Int, name: String, uploads: [GiovUploadProgress], strings: GiovChatStrings) -> String {
    guard index < uploads.count else { return name }
    let percent = Int((min(max(uploads[index].progress, 0), 1) * 100).rounded(.down))
    return strings.uploading(percent)
}

/// The problems of a pick as one sentence, or nil when there are none.
func giovProblemText(_ problems: [GiovAttachmentProblem], strings: GiovChatStrings) -> String? {
    guard !problems.isEmpty else { return nil }
    return problems.map { strings.describeProblem($0) }.joined(separator: " ")
}

/// The name an attachment is shown and announced under.
func giovAttachmentName(_ attachment: GiovAttachment, strings: GiovChatStrings) -> String {
    let name = attachment.displayName
    if !name.isEmpty { return name }
    return attachment.isImage ? strings.image : strings.attachment
}

/// Whether `url` is an http(s) URL (the only kind the screen downloads or opens for attachments).
func giovIsHTTPURL(_ url: String) -> Bool {
    let lower = url.lowercased()
    return lower.hasPrefix("https://") || lower.hasPrefix("http://")
}

/// The largest box an image attachment takes, in points.
let giovMaxImageSize = (width: 200.0, height: 150.0)

/// The box an image takes before it loads: its final shape scaled into 200 x 150, or 200 x 150 when the shape is
/// unknown, so the list does not jump when the picture arrives.
func giovPreviewBoxSize(_ preview: GiovAttachmentPreview?) -> (width: Double, height: Double) {
    guard let width = preview?.width, let height = preview?.height, width > 0, height > 0 else {
        return giovMaxImageSize
    }
    let scale = min(1, min(giovMaxImageSize.width / Double(width), giovMaxImageSize.height / Double(height)))
    return (max(1, (Double(width) * scale).rounded()), max(1, (Double(height) * scale).rounded()))
}

/// `something@domain.tld`: the widget's `^[^\s@]+@[^\s@]+\.[^\s@]+$`.
func giovLooksLikeEmail(_ value: String) -> Bool {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.contains(where: \.isWhitespace) else { return false }
    let parts = text.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty else { return false }
    let domain = Array(parts[1])
    return domain.indices.contains { $0 > 0 && $0 < domain.count - 1 && domain[$0] == "." }
}

/// The pre-chat form's values for the fields the workspace asks for.
struct GiovPreChatValues: Sendable, Equatable {
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""

    init(firstName: String = "", lastName: String = "", email: String = "", phone: String = "") {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
    }

    /// Pre-filled from what the host already knows.
    init(contact: GiovContact?) {
        self.init(
            firstName: contact?.firstName ?? "",
            lastName: contact?.lastName ?? "",
            email: contact?.email ?? "",
            phone: contact?.phone ?? ""
        )
    }

    /// Every required field is filled in, and the email looks like one.
    func isValid(for fields: GiovRequestUserInfo) -> Bool {
        func filled(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (!fields.firstName || filled(firstName))
            && (!fields.lastName || filled(lastName))
            && (!fields.email || giovLooksLikeEmail(email))
            && (!fields.phone || filled(phone))
    }

    /// The contact to submit: trimmed, blanks left out.
    var contact: GiovContact {
        func clean(_ value: String) -> String? {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return GiovContact(email: clean(email), phone: clean(phone), firstName: clean(firstName), lastName: clean(lastName))
    }
}

/// What makes the conversation list follow new content: a new row, a growing reply, the typing row, a phase change.
struct GiovScrollSignature: Sendable, Equatable {
    var count: Int
    var lastKey: String?
    var lastLength: Int
    var typing: Bool
    var phase: GiovChatPhase

    init(_ state: GiovChatUiState) {
        count = state.messages.count
        lastKey = state.messages.last?.key
        lastLength = state.messages.last?.content.utf16.count ?? 0
        typing = state.agentTyping
        phase = state.phase
    }
}
