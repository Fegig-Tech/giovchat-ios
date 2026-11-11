import Foundation

// Who the visitor is talking to and who wrote each message (docs/protocol/README.md, "Identity (who wrote it, who
// is in the header)"), as the web widget shows it.

public enum GiovHeaderKind: String, Sendable, Equatable {
    case person, bot, team
}

/// What the chat header shows.
public struct GiovHeaderIdentity: Sendable, Equatable {
    public var kind: GiovHeaderKind
    public var title: String
    /// An http(s) image URL, or nil (show the initial).
    public var avatar: String?

    public init(kind: GiovHeaderKind, title: String, avatar: String? = nil) {
        self.kind = kind
        self.title = title
        self.avatar = avatar
    }

    /// The status line under the title.
    public func status(_ strings: GiovChatStrings) -> String {
        switch kind {
        case .person: return strings.statusPerson
        case .bot: return strings.statusBot
        case .team: return strings.statusTeam
        }
    }
}

/// First match wins: a person once one has written or history names an assigned teammate; else the bot while it
/// answers (`botEnabled` and `botName`); else the team (`title`, `avatarURL`).
public func giovHeaderIdentity(_ config: GiovWidgetConfig, agentName: String? = nil, agentAvatar: String? = nil) -> GiovHeaderIdentity {
    if let agentName, !agentName.isEmpty {
        return GiovHeaderIdentity(kind: .person, title: agentName, avatar: safeHTTPURL(agentAvatar))
    }
    if config.botEnabled, let botName = config.botName, !botName.isEmpty {
        return GiovHeaderIdentity(kind: .bot, title: botName, avatar: safeHTTPURL(config.botAvatarURL))
    }
    return GiovHeaderIdentity(kind: .team, title: config.title, avatar: safeHTTPURL(config.avatarURL))
}

/// The label above a bubble. AI replies are also automated internally; the AI identity wins. `agentName` is the
/// assigned teammate, used for people's messages that carry no name (history).
public func giovMessageSenderLabel(_ message: GiovMessage, strings: GiovChatStrings, botName: String? = nil, agentName: String? = nil) -> String {
    func trimmed(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    if message.role != .agent { return strings.you }
    if message.isBot { return trimmed(botName) ?? "GiovBot" }
    if message.isAutomated { return strings.automated }
    if let name = trimmed(message.senderName) { return name }
    return trimmed(agentName) ?? strings.agent
}

/// Whether the agent-side typing indicator shows and whether it is the bot's.
struct GiovTypingState: Sendable, Equatable {
    var visible = false
    /// Nil when the server did not say; only explicit metadata brands the indicator as the AI.
    var isBot: Bool?
}

/// Applies a `typing` / `typing_end` frame. A `typing_end` for the other kind (bot vs team) keeps the current
/// indicator.
func reduceAgentTyping(_ current: GiovTypingState, frame: [String: JSONValue]) -> GiovTypingState {
    guard frame.at("role").string == "agent" else { return current }
    let isBot = frame.at("isBot").bool
    switch frame.at("type").string {
    case "typing":
        return GiovTypingState(visible: true, isBot: isBot)
    case "typing_end":
        if let isBot, let currentBot = current.isBot, isBot != currentBot { return current }
        return GiovTypingState()
    default:
        return current
    }
}
