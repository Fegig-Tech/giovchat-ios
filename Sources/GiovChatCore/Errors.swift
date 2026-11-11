import Foundation

/// A typed failure. The SDK never shows a server's `error` code to people; the UI maps each ``Kind`` to a
/// translated sentence with ``GiovChatStrings/describeError(_:)``.
///
/// ``message`` is for logs, in English. ``status`` is the HTTP status when the failure came from a response and
/// ``code`` the server's `error` field when it sent one.
public struct GiovChatError: Error, Sendable, Equatable, CustomStringConvertible {
    /// What went wrong; mirrors the Android SDK's `GiovChatException` subclasses.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The network could not be reached, or a request timed out (see ``GiovChatError/timedOut``).
        case network
        /// The stored session is gone (expired, foreign, deleted). The SDK forgets it; the next message starts a
        /// new conversation.
        case sessionExpired
        /// The team closed the conversation (or it was deleted). The next message starts a new one.
        case conversationClosed
        /// `429 rate_limited`: wait ``GiovChatError/retryAfterSeconds`` before trying again.
        case rateLimited
        /// `503 workspace_busy`: the workspace is at its plan's limit of open conversations.
        case workspaceBusy
        /// `401 invalid_user_hash`: the workspace requires a signed identity and the one given is wrong.
        case identityRejected
        /// An upload was refused (type, size, or the bot's attachment policy). In ``GiovChatUiState/error`` it also
        /// stands for an upload that failed for another reason (network, rate limit, server), with that failure's
        /// `status`, `code` and `retryAfterSeconds`; `onError` receives the original kind.
        case attachmentRejected
        /// A message could not be delivered (refused frame, or three failed saves).
        case sendFailed
        /// The server answered something the protocol does not allow.
        case invalidResponse
        /// The chat was closed (or the client disposed) while a call was in flight.
        case disconnected
        /// The ``GiovSessionStore`` failed to read, write or delete the stored session.
        case storage
        /// Any other refusal (`404 tenant_not_found`, `5xx`, ...).
        case server
    }

    public let kind: Kind
    /// English, for logs.
    public let message: String
    /// The HTTP status, when the failure came from a response.
    public let status: Int?
    /// The server's `error` field, when it sent one.
    public let code: String?
    /// For ``Kind/network``: the request or connection timed out.
    public let timedOut: Bool
    /// For ``Kind/rateLimited`` and ``Kind/workspaceBusy``: the server's `Retry-After`, in seconds.
    public let retryAfterSeconds: Int?
    /// A description of the underlying platform error (for ``Kind/network`` and ``Kind/storage``), if any.
    public let underlying: String?

    public init(
        _ kind: Kind,
        _ message: String,
        status: Int? = nil,
        code: String? = nil,
        timedOut: Bool = false,
        retryAfterSeconds: Int? = nil,
        underlying: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.status = status
        self.code = code
        self.timedOut = timedOut
        self.retryAfterSeconds = retryAfterSeconds
        self.underlying = underlying
    }

    public var description: String {
        var text = "GiovChatError.\(kind.rawValue): \(message)"
        if let status {
            text += " (\(status)\(code.map { " \($0)" } ?? ""))"
        }
        return text
    }

    static func network(_ message: String, timedOut: Bool = false, underlying: Error? = nil) -> GiovChatError {
        GiovChatError(.network, message, timedOut: timedOut, underlying: underlying.map { String(describing: $0) })
    }

    static func sessionExpired(_ message: String, status: Int? = nil, code: String? = nil) -> GiovChatError {
        GiovChatError(.sessionExpired, message, status: status, code: code)
    }

    static func conversationClosed(_ message: String = "This conversation has ended.", status: Int? = nil, code: String? = nil) -> GiovChatError {
        GiovChatError(.conversationClosed, message, status: status, code: code)
    }

    static func rateLimited(_ message: String, retryAfterSeconds: Int) -> GiovChatError {
        GiovChatError(.rateLimited, message, status: 429, code: "rate_limited", retryAfterSeconds: retryAfterSeconds)
    }

    static func workspaceBusy(_ message: String, retryAfterSeconds: Int) -> GiovChatError {
        GiovChatError(.workspaceBusy, message, status: 503, code: "workspace_busy", retryAfterSeconds: retryAfterSeconds)
    }

    static func identityRejected(_ message: String) -> GiovChatError {
        GiovChatError(.identityRejected, message, status: 401, code: "invalid_user_hash")
    }

    static func attachmentRejected(_ message: String, status: Int? = nil, code: String? = nil) -> GiovChatError {
        GiovChatError(.attachmentRejected, message, status: status, code: code)
    }

    static func sendFailed(_ message: String, code: String? = nil) -> GiovChatError {
        GiovChatError(.sendFailed, message, code: code)
    }

    static func invalidResponse(_ message: String, status: Int? = nil) -> GiovChatError {
        GiovChatError(.invalidResponse, message, status: status)
    }

    static func disconnected(_ message: String = "Chat closed.") -> GiovChatError {
        GiovChatError(.disconnected, message)
    }

    static func storage(_ message: String, underlying: Error? = nil) -> GiovChatError {
        GiovChatError(.storage, message, underlying: underlying.map { String(describing: $0) })
    }

    static func server(_ message: String, status: Int? = nil, code: String? = nil) -> GiovChatError {
        GiovChatError(.server, message, status: status, code: code)
    }
}

extension Error {
    /// This error as a ``GiovChatError``; anything else counts as a network failure.
    var asGiovError: GiovChatError {
        if let error = self as? GiovChatError { return error }
        return .network(String(describing: self), underlying: self)
    }
}
