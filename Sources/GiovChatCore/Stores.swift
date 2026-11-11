import Foundation

/// Where the session secret lives between launches: the `{conversationId, sessionToken}` pair, one per scope.
///
/// The session token is a bearer secret that proves this device owns the conversation. On Apple platforms use
/// ``KeychainGiovSessionStore`` (the controller's default there); ``InMemoryGiovSessionStore`` forgets the
/// conversation when the process ends.
///
/// Implementations may throw; the SDK reports a ``GiovChatError/Kind/storage`` failure and carries on without the
/// stored session.
public protocol GiovSessionStore: Sendable {
    /// The stored session for `scope`, or nil.
    func read(scope: String) async throws -> GiovSession?
    func write(scope: String, session: GiovSession) async throws
    func delete(scope: String) async throws
}

/// Keeps sessions for the life of the process only.
public actor InMemoryGiovSessionStore: GiovSessionStore {
    private var sessions: [String: GiovSession] = [:]

    public init() {}

    public func read(scope: String) async throws -> GiovSession? { sessions[scope] }

    public func write(scope: String, session: GiovSession) async throws { sessions[scope] = session }

    public func delete(scope: String) async throws { sessions[scope] = nil }
}

/// The key a session is stored under: one per API, workspace, `sessionKey` and signed-in `userId`, so signing in as
/// someone else never resumes the previous person's conversation. Names, email and phone are not part of it: editing
/// them (or filling in the pre-chat form) keeps the visitor's conversation. A JSON array, as in the other Giov SDKs.
public func giovSessionScope(baseURL: String, tenantKey: String, contact: GiovContact? = nil, sessionKey: String? = nil) -> String {
    var base = baseURL
    while base.hasSuffix("/") { base.removeLast() }
    let parts: [String?] = [base, tenantKey, sessionKey, contact?.userId]
    return JSONValue.array(parts.map { $0.map(JSONValue.string) ?? .null }).serialized
}

private let sessionTokenPattern = Pattern("^[a-f0-9]{64}\\z")

/// A session token is 64 lowercase hex characters.
func isValidSessionToken(_ token: String?) -> Bool {
    guard let token else { return false }
    return sessionTokenPattern.matches(token)
}

/// A stored pair is used only if it looks like one.
func isValidStoredSession(_ session: GiovSession?) -> Bool {
    guard let session else { return false }
    return !session.conversationId.isEmpty && isValidSessionToken(session.sessionToken)
}
