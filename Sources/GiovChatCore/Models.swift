import Foundation

// Data the visitor protocol carries (docs/protocol/visitor-api.openapi.yaml and visitor-realtime.asyncapi.yaml),
// parsed defensively: unknown fields are ignored and malformed values fall back instead of throwing.

/// `light`, `dark`, or `auto` (follow the device).
public enum GiovThemeMode: String, Sendable, Equatable, CaseIterable {
    case light, dark, auto
}

/// Fields the workspace asks for in a pre-chat form before the first message.
public struct GiovRequestUserInfo: Sendable, Equatable {
    public var email: Bool
    public var phone: Bool
    public var firstName: Bool
    public var lastName: Bool

    public init(email: Bool = false, phone: Bool = false, firstName: Bool = false, lastName: Bool = false) {
        self.email = email
        self.phone = phone
        self.firstName = firstName
        self.lastName = lastName
    }

    /// At least one field is asked for.
    public var any: Bool { email || phone || firstName || lastName }

    static func fromJSON(_ json: JSONValue?) -> GiovRequestUserInfo {
        let map = json.object
        return GiovRequestUserInfo(
            email: map.at("email").isTrue,
            phone: map.at("phone").isTrue,
            firstName: map.at("firstName").isTrue,
            lastName: map.at("lastName").isTrue
        )
    }
}

/// `GET /widget/config`: everything the business set up for its chat.
public struct GiovWidgetConfig: Sendable, Equatable {
    /// The widget's default brand colour when the configured one cannot be parsed.
    public static let defaultPrimaryColor = "#7c3aed"
    static let defaultGreeting = "Hi! How can we help?"

    /// The team's name, for the header when neither a person nor the bot answers.
    public var title: String
    /// Brand colour as sent, usually `#rrggbb`.
    public var primaryColor: String
    /// Shown before the visitor writes. Plain text.
    public var greetingText: String
    /// Composer placeholder.
    public var textArea: String?
    public var theme: GiovThemeMode
    public var botEnabled: Bool
    public var botName: String?
    public var botAvatarURL: String?
    public var avatarURL: String?
    /// The answering GiovBot's attachment rules; nil when no bot is published (then images only).
    public var attachments: GiovAttachmentPolicy?
    public var showBranding: Bool
    public var privacyPolicyURL: String?
    public var requestUserInfo: GiovRequestUserInfo
    /// `bubble` or `pill`.
    public var launcherStyle: String

    public init(
        title: String,
        primaryColor: String = GiovWidgetConfig.defaultPrimaryColor,
        greetingText: String = "Hi! How can we help?",
        textArea: String? = nil,
        theme: GiovThemeMode = .auto,
        botEnabled: Bool = false,
        botName: String? = nil,
        botAvatarURL: String? = nil,
        avatarURL: String? = nil,
        attachments: GiovAttachmentPolicy? = nil,
        showBranding: Bool = true,
        privacyPolicyURL: String? = nil,
        requestUserInfo: GiovRequestUserInfo = GiovRequestUserInfo(),
        launcherStyle: String = "bubble"
    ) {
        self.title = title
        self.primaryColor = primaryColor
        self.greetingText = greetingText
        self.textArea = textArea
        self.theme = theme
        self.botEnabled = botEnabled
        self.botName = botName
        self.botAvatarURL = botAvatarURL
        self.avatarURL = avatarURL
        self.attachments = attachments
        self.showBranding = showBranding
        self.privacyPolicyURL = privacyPolicyURL
        self.requestUserInfo = requestUserInfo
        self.launcherStyle = launcherStyle
    }

    /// What a visitor may attach right now: the bot's policy, or the server's default (images).
    public var attachmentPolicy: GiovAttachmentPolicy { attachments ?? .default }

    static func fromJSON(_ json: [String: JSONValue]) -> GiovWidgetConfig {
        GiovWidgetConfig(
            title: json.at("title").nonEmpty ?? "Support",
            primaryColor: json.at("primaryColor").string ?? defaultPrimaryColor,
            greetingText: json.at("greetingText").string ?? defaultGreeting,
            textArea: json.at("textArea").nonEmpty,
            theme: json.at("theme").string.flatMap(GiovThemeMode.init(rawValue:)) ?? .auto,
            botEnabled: json.at("botEnabled").isTrue,
            botName: json.at("botName").nonEmpty,
            botAvatarURL: safeHTTPURL(json["botAvatarUrl"]),
            avatarURL: safeHTTPURL(json["avatarUrl"]),
            attachments: GiovAttachmentPolicy.fromJSON(json["attachments"]),
            // Only an explicit false removes the branding (a server-resolved plan policy).
            showBranding: !json.at("showBranding").isFalse,
            privacyPolicyURL: safeHTTPURL(json["privacyPolicyUrl"]),
            requestUserInfo: GiovRequestUserInfo.fromJSON(json["requestUserInfo"]),
            launcherStyle: json.at("launcherStyle").string == "pill" ? "pill" : "bubble"
        )
    }
}

/// Contact details the host app knows. All untrusted except a ``userId`` with its ``userHash``; see "Identity"
/// in docs/protocol/README.md.
public struct GiovContact: Sendable, Equatable {
    /// Your stable customer id. Trusted only together with ``userHash``.
    public var userId: String?
    /// `HMAC-SHA256(identity secret, userId)`, lowercase hex, computed on YOUR server. Never ship the identity
    /// secret in an app.
    public var userHash: String?
    public var email: String?
    public var phone: String?
    public var firstName: String?
    public var lastName: String?

    public init(
        userId: String? = nil,
        userHash: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil
    ) {
        self.userId = userId
        self.userHash = userHash
        self.email = email
        self.phone = phone
        self.firstName = firstName
        self.lastName = lastName
    }

    /// These details with the non-nil fields of `other` on top.
    public func merging(_ other: GiovContact) -> GiovContact {
        GiovContact(
            userId: other.userId ?? userId,
            userHash: other.userHash ?? userHash,
            email: other.email ?? email,
            phone: other.phone ?? phone,
            firstName: other.firstName ?? firstName,
            lastName: other.lastName ?? lastName
        )
    }

    /// The fields `POST /conversations` accepts; empty values are left out and the rest is trimmed.
    var startFields: [String: String] {
        var fields: [String: String] = [:]
        let pairs: [(String, String?)] = [
            ("userId", userId), ("userHash", userHash), ("email", email),
            ("phone", phone), ("firstName", firstName), ("lastName", lastName),
        ]
        for (key, value) in pairs {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                fields[key] = trimmed
            }
        }
        return fields
    }
}

/// The private proof that this device owns a conversation. Store it securely; never log it.
public struct GiovSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let conversationId: String
    public let sessionToken: String

    public init(conversationId: String, sessionToken: String) {
        self.conversationId = conversationId
        self.sessionToken = sessionToken
    }

    public var description: String { "GiovSession(\(conversationId))" }
    public var debugDescription: String { description }
}

public enum GiovRole: String, Sendable, Equatable {
    case visitor, agent
}

/// Local delivery state of a visitor message.
public enum GiovDelivery: String, Sendable, Equatable {
    case sending, sent, failed
}

/// One message in the conversation, from the socket, history or this device.
public struct GiovMessage: Sendable, Equatable, Identifiable {
    /// The stored id, or the client id while the message is still on its way.
    public var id: String
    public var role: GiovRole
    /// Chat markdown; render it with ``GiovChatMarkdown``.
    public var content: String
    /// Unix milliseconds.
    public var createdAt: Int
    /// Written by GiovBot.
    public var isBot: Bool
    /// An automatic notice (away message, bot failure notice); not a person.
    public var isAutomated: Bool
    /// The person who wrote it, for team messages; nil for the bot and notices.
    public var senderName: String?
    public var senderAvatar: String?
    public var attachments: [GiovAttachment]
    public var delivery: GiovDelivery
    /// The id this message was shown under before the server confirmed it. Use ``key`` for list identity.
    public var clientMessageId: String?
    /// For a bot reply: the visitor message it answers.
    public var streamId: String?
    /// A GiovBot reply still being written.
    public var isStreaming: Bool

    public init(
        id: String,
        role: GiovRole,
        content: String,
        createdAt: Int,
        isBot: Bool = false,
        isAutomated: Bool = false,
        senderName: String? = nil,
        senderAvatar: String? = nil,
        attachments: [GiovAttachment] = [],
        delivery: GiovDelivery = .sent,
        clientMessageId: String? = nil,
        streamId: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isBot = isBot
        self.isAutomated = isAutomated
        self.senderName = senderName
        self.senderAvatar = senderAvatar
        self.attachments = attachments
        self.delivery = delivery
        self.clientMessageId = clientMessageId
        self.streamId = streamId
        self.isStreaming = isStreaming
    }

    /// A stable list key: it is the same before and after the server stores the message and when a streamed
    /// draft becomes the saved reply, so a lazy list does not rebuild the bubble (or reload its images).
    public var key: String {
        if let clientMessageId { return clientMessageId }
        if let streamId, isBot { return "stream:\(streamId)" }
        return id
    }

    /// Written by a person on the team (the header identity's "person" signal).
    public var isFromPerson: Bool { role == .agent && !isBot && !isAutomated }

    /// A message from a socket frame (camelCase) or a history row (camelCase, with the deprecated snake_case
    /// names as a fallback). The visitor's role is `user` in history and `visitor` on the socket. Returns nil for
    /// anything that is not a message.
    static func fromJSON(_ json: JSONValue?) -> GiovMessage? {
        let map = json.object
        let role: GiovRole
        switch map.at("role").string {
        case "user", "visitor": role = .visitor
        case "agent": role = .agent
        default: return nil
        }
        guard let id = map.at("id").nonEmpty,
              let content = map.at("content").string,
              let createdAt = (map["createdAt"] ?? map["created_at"]).int
        else { return nil }
        let agent = role == .agent
        let isBot = agent && (map.at("isBot").isTrue || map.at("is_bot").number == 1)
        let isAutomated = agent && (map.at("isAutomated").isTrue || map.at("is_automated").number == 1)
        let person = agent && !isBot && !isAutomated
        return GiovMessage(
            id: id,
            role: role,
            content: content,
            createdAt: createdAt,
            isBot: isBot,
            isAutomated: isAutomated,
            senderName: agent ? map.at("senderName").nonEmpty : nil,
            senderAvatar: person ? safeHTTPURL(map["senderAvatar"]) : nil,
            attachments: parseAttachments(map["attachmentId"] ?? map["attachment_id"], previews: map["attachmentPreviews"] ?? map["attachment_previews"]),
            streamId: map.at("streamId").nonEmpty
        )
    }
}

/// `GET /conversations/{id}/history`, parsed.
public struct GiovHistory: Sendable, Equatable {
    public var messages: [GiovMessage]
    /// The team closed the conversation.
    public var closed: Bool
    public var assignedAgentName: String?
    public var assignedAgentAvatar: String?
    public var attachmentAccess: GiovAttachmentAccess?

    static func fromJSON(_ json: [String: JSONValue]) -> GiovHistory {
        let assignedName = json.at("assignedAgentName").nonEmpty
        let messages = (json.at("messages").array ?? []).compactMap { row -> GiovMessage? in
            guard var message = GiovMessage.fromJSON(row) else { return nil }
            // History rows carry no sender; a person's message is shown under the assigned teammate.
            if message.isFromPerson, message.senderName == nil, let assignedName { message.senderName = assignedName }
            return message
        }
        return GiovHistory(
            messages: messages,
            closed: json.at("status").string == "closed",
            assignedAgentName: assignedName,
            assignedAgentAvatar: assignedName != nil ? safeHTTPURL(json["assignedAgentAvatar"]) : nil,
            attachmentAccess: GiovAttachmentAccess.fromJSON(json["attachmentAccess"])
        )
    }
}

/// `POST /auth/widget-token`: the 15-minute visitor token.
struct VisitorToken: Sendable, Equatable {
    let token: String
    /// Unix milliseconds.
    let expiresAt: Int
    let attachmentAccess: GiovAttachmentAccess?

    /// Renew before every connect and when less than a minute is left.
    func usable(at nowMs: Int) -> Bool { expiresAt - nowMs > 60_000 }

    /// `expiresAt` is Unix **seconds**, the one time in seconds in the protocol; assume a little under 15 minutes
    /// when absent.
    static func fromJSON(_ json: [String: JSONValue], now nowMs: Int) -> VisitorToken? {
        guard let token = json.at("token").nonEmpty else { return nil }
        let expiresAt = json.at("expiresAt").number.flatMap { safeInt($0 * 1000) } ?? nowMs + 14 * 60_000
        return VisitorToken(token: token, expiresAt: expiresAt, attachmentAccess: GiovAttachmentAccess.fromJSON(json["attachmentAccess"]))
    }
}
