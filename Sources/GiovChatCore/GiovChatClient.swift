import Foundation

// The visitor protocol client (docs/protocol/README.md): configuration, starting and resuming a conversation,
// visitor tokens, the conversation socket with its heartbeat and reconnects, history, streaming replies, typing,
// uploads and push registration. No UI.
//
// The client is transport only. It reports what happens through `ClientEvents` and leaves the protocol's catch-up
// order (open, history, merge, resend) to its owner, normally GiovChatController: construct it with
// `flushOnOpen: false`, call `connect`, load `fetchHistory`, merge, then `flush`.
//
// Threading: main actor only; socket callbacks arrive there, HTTP results are awaited there.

/// Connection timings from the visitor protocol.
let socketOpenTimeoutMs = 10_000
let socketPingIntervalMs = 25_000
let socketPongTimeoutMs = 10_000
let requestTimeoutMs = 15_000
let uploadTimeoutMs = 120_000
private let watchdogIntervalMs = 3_000
private let rateLimitPauseMs = 3_000
private let deletedReason = "Conversation deleted"
private let pingFrame = #"{"type":"ping"}"#

/// Retry waits: `min(1500 x 2^attempt, 15000)` ms plus a little jitter (0 to 400 ms, `jitter` in 0...1); the attempt
/// counter resets after a successful connect.
public func giovReconnectDelayMs(attempt: Int, jitter: Double = 0) -> Int {
    let base = attempt >= 4 ? 15_000 : min(1500 << max(attempt, 0), 15_000)
    return base + Int(min(max(jitter, 0), 1) * 400)
}

/// A GiovBot reply arriving word by word: the whole text so far, then an end once it is saved or dropped.
enum StreamEvent: Sendable, Equatable {
    /// The WHOLE reply so far, not a delta.
    case update(streamId: String, content: String)
    case end(streamId: String)

    var streamId: String {
        switch self {
        case .update(let streamId, _), .end(let streamId): return streamId
        }
    }
}

/// What the client reports, on the main actor, synchronously, in the order things happen.
struct ClientEvents {
    /// Chat messages from the socket. A saved GiovBot reply carries `clientMessageId == "stream:<streamId>"`.
    var message: (GiovMessage) -> Void = { _ in }
    /// The server stored a visitor message; the message replaces the optimistic copy, in place.
    var ack: (_ clientMessageId: String, GiovMessage) -> Void = { _, _ in }
    var stream: (StreamEvent) -> Void = { _ in }
    /// The agent side started or stopped typing. `isBot` is nil when the server did not say; a `typing_end` with
    /// `isBot` only ends an indicator of the same kind (visitor-realtime.asyncapi.yaml, `TypingEnd`).
    var typing: (_ active: Bool, _ isBot: Bool?) -> Void = { _, _ in }
    /// True when a socket opens, false when it closes or the client disconnects.
    var connection: (Bool) -> Void = { _ in }
    /// Failures that are not the answer to a call: refused messages, a dead session, a deleted conversation.
    var error: (GiovChatError) -> Void = { _ in }
    /// A newer attachment download token arrived (with a visitor token, an upload or history).
    var attachmentAccess: (GiovAttachmentAccess) -> Void = { _ in }
}

struct GiovUploadResult: Sendable, Equatable {
    let url: String
    let filename: String
    let preview: GiovAttachmentPreview?
}

private struct Reply {
    let status: Int
    let body: [String: JSONValue]
    let retryAfterSeconds: Int

    var ok: Bool { (200...299).contains(status) }
    var code: String? { body.at("error").string }
}

private struct TimedOut: Error {}

/// Runs `operation`, cancelling it after `ms` on `clock`.
func giovWithTimeout<T: Sendable>(_ ms: Int, clock: any GiovClock, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(ms: ms)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        guard let value = first else { throw TimedOut() }
        return value
    }
}

@MainActor
final class GiovChatClient {
    /// The workspace key (public).
    let tenantKey: String
    let baseURL: String
    /// Messages waiting for the server; pass one that outlives this client.
    let outbox: Outbox
    /// Send the outbox as soon as a socket opens. The controller turns this off and calls `flush` after the history
    /// catch-up.
    private let flushOnOpen: Bool
    /// BCP 47 language sent with push registrations.
    private let locale: String?
    private let http: any GiovHTTP
    private let socketFactory: any GiovSocketFactory
    private let clock: any GiovClock
    private let random: @Sendable () -> Double
    private let clientMarker: String

    var events: ClientEvents?

    private var socket: (any GiovSocket)?
    private var dropSocket: (() -> Void)?
    private var cancelHandshake: (() -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var resendTasks: [Int: Task<Void, Never>] = [:]
    private var nextResend = 0
    private var generation = 0
    private var desired = false
    private var disposed = false
    private var attempt = 0
    private var currentSession: GiovSession?
    private var currentToken: VisitorToken?
    private var tokenRequest: (id: Int, task: Task<VisitorToken, Error>)?
    private var nextTokenRequest = 0
    private var pushUnsupported = false

    init(
        tenantKey: String,
        baseURL: String,
        outbox: Outbox,
        flushOnOpen: Bool = true,
        locale: String? = nil,
        http: any GiovHTTP,
        socketFactory: any GiovSocketFactory,
        clock: any GiovClock,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        clientMarker: String = "ios/\(GiovChatVersion.current)"
    ) {
        self.tenantKey = tenantKey
        self.baseURL = baseURL
        self.outbox = outbox
        self.flushOnOpen = flushOnOpen
        self.locale = locale
        self.http = http
        self.socketFactory = socketFactory
        self.clock = clock
        self.random = random
        self.clientMarker = clientMarker
    }

    var isConnected: Bool { socket?.isOpen ?? false }

    /// The conversation this client is connected (or connecting) to.
    var session: GiovSession? { currentSession }

    /// The current visitor token, a fallback credential for attachment downloads.
    var visitorToken: String? { currentToken?.token }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, headers: [String: String] = [:], json: [String: JSONValue]? = nil) async throws -> Reply {
        var allHeaders = headers
        if json != nil { allHeaders["Content-Type"] = "application/json" }
        let request = GiovHTTPRequest(method: method, url: baseURL + path, headers: allHeaders, jsonBody: json.map { JSONValue.object($0).serialized })
        let http = self.http
        let response: GiovHTTPResponse
        do {
            response = try await giovWithTimeout(requestTimeoutMs, clock: clock) { try await http.send(request) }
        } catch is TimedOut {
            throw GiovChatError.network("Chat request timed out.", timedOut: true)
        } catch let error as GiovChatError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GiovChatError.network(String(describing: error), underlying: error)
        }
        return reply(response)
    }

    private func reply(_ response: GiovHTTPResponse) -> Reply {
        let retryAfter = response.headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 30
        return Reply(status: response.status, body: parseJSONObject(response.body), retryAfterSeconds: retryAfter)
    }

    /// Maps an unsuccessful reply to the SDK's typed failures (README, "Errors, limits and headers"). On routes that
    /// take the session, 401/403 mean the session is gone.
    private func failure(_ reply: Reply, sessionRoute: Bool = false) -> GiovChatError {
        let code = reply.code
        let message = reply.body.at("message").string ?? code ?? "HTTP \(reply.status)"
        if code == "invalid_user_hash" { return .identityRejected(message) }
        if reply.status == 429 { return .rateLimited(message, retryAfterSeconds: reply.retryAfterSeconds) }
        if reply.status == 503 && code == "workspace_busy" { return .workspaceBusy(message, retryAfterSeconds: reply.retryAfterSeconds) }
        if reply.status == 409 || code == "conversation_closed" { return .conversationClosed(message, status: reply.status, code: code) }
        if sessionRoute && (reply.status == 401 || reply.status == 403) { return .sessionExpired(message, status: reply.status, code: code) }
        return .server(message, status: reply.status, code: code)
    }

    /// `GET /widget/config`, with the client marker header.
    func fetchWidgetConfig() async throws -> GiovWidgetConfig {
        let reply = try await request("GET", "/widget/config?tenantId=\(encodeComponent(tenantKey))", headers: ["X-Giov-Client": clientMarker])
        guard reply.ok else { throw failure(reply) }
        guard reply.body.at("title").string != nil else { throw GiovChatError.invalidResponse("Invalid widget configuration.") }
        return GiovWidgetConfig.fromJSON(reply.body)
    }

    /// `POST /conversations` without a session: starts a new conversation. Call it when the visitor sends the first
    /// message or submits the pre-chat form, never just for opening the screen.
    func startConversation(contact: GiovContact? = nil) async throws -> GiovSession {
        try await conversation(contact: contact, existing: nil)
    }

    /// `POST /conversations` with the stored session: resumes it. Throws `sessionExpired` / `conversationClosed` (or
    /// a 404 `server` failure) when the stored pair must be forgotten.
    func resumeConversation(_ session: GiovSession, contact: GiovContact? = nil) async throws -> GiovSession {
        try await conversation(contact: contact, existing: session)
    }

    private func conversation(contact: GiovContact?, existing: GiovSession?) async throws -> GiovSession {
        var body: [String: JSONValue] = ["tenantId": .string(tenantKey)]
        for (key, value) in contact?.startFields ?? [:] { body[key] = .string(value) }
        if let existing { body["conversationId"] = .string(existing.conversationId) }
        let reply = try await request(
            "POST",
            "/conversations",
            headers: existing.map { ["Authorization": "Bearer \($0.sessionToken)"] } ?? [:],
            json: body
        )
        guard reply.ok else { throw failure(reply, sessionRoute: existing != nil) }
        guard let id = reply.body.at("conversationId").string, !id.isEmpty,
              let token = reply.body.at("sessionToken").string, isValidSessionToken(token)
        else { throw GiovChatError.invalidResponse("Invalid chat session response.") }
        return GiovSession(conversationId: id, sessionToken: token)
    }

    private func fetchToken(_ session: GiovSession) async throws -> VisitorToken {
        let reply = try await request(
            "POST",
            "/auth/widget-token",
            headers: ["Authorization": "Bearer \(session.sessionToken)"],
            json: ["tenantId": .string(tenantKey), "conversationId": .string(session.conversationId)]
        )
        guard reply.ok else { throw failure(reply, sessionRoute: true) }
        guard let token = VisitorToken.fromJSON(reply.body, now: clock.now()) else {
            throw GiovChatError.invalidResponse("Invalid chat token response.")
        }
        return token
    }

    /// The visitor token; renewed when less than a minute is left. One request at a time.
    private func token(force: Bool = false) async throws -> VisitorToken {
        guard let session = currentSession else { throw GiovChatError.disconnected() }
        if !force, let cached = currentToken, cached.usable(at: clock.now()) { return cached }
        let pending: Task<VisitorToken, Error>
        if let existing = tokenRequest {
            pending = existing.task
        } else {
            let id = nextTokenRequest
            nextTokenRequest += 1
            pending = Task { @MainActor [weak self] in
                guard let self else { throw GiovChatError.disconnected() }
                defer { if self.tokenRequest?.id == id { self.tokenRequest = nil } }
                let value = try await self.fetchToken(session)
                if self.currentSession == session, !Task.isCancelled {
                    self.currentToken = value
                    if let access = value.attachmentAccess { self.events?.attachmentAccess(access) }
                }
                return value
            }
            tokenRequest = (id, pending)
        }
        return try await pending.value
    }

    /// A call with the visitor token: a 401 renews the token once and retries; a second 401 means the session is gone.
    private func authed(_ method: String, _ path: String, headers: [String: String] = [:], json: [String: JSONValue]? = nil) async throws -> Reply {
        var token = try await token()
        var reply = try await request(method, path, headers: headers.merging(["Authorization": "Bearer \(token.token)"]) { $1 }, json: json)
        if reply.status == 401 {
            token = try await self.token(force: true)
            reply = try await request(method, path, headers: headers.merging(["Authorization": "Bearer \(token.token)"]) { $1 }, json: json)
        }
        return reply
    }

    private func conversationPath() throws -> String {
        guard let session = currentSession else { throw GiovChatError.disconnected() }
        return "/conversations/\(encodeComponent(session.conversationId))"
    }

    /// `GET /conversations/{id}/history` for the connected session. A 404 is a `server` failure with `status == 404`:
    /// the conversation is gone, forget it.
    func fetchHistory() async throws -> GiovHistory {
        let path = try conversationPath() + "/history"
        let reply = try await authed("GET", path)
        guard reply.ok else { throw failure(reply, sessionRoute: true) }
        guard reply.body.at("messages").array != nil else { throw GiovChatError.invalidResponse("Invalid conversation history.") }
        let history = GiovHistory.fromJSON(reply.body)
        if let access = history.attachmentAccess { events?.attachmentAccess(access) }
        return history
    }

    // MARK: - Socket

    private func socketURL(_ session: GiovSession, token: String) -> String {
        // The base URL is validated as http(s); its scheme may be written in any case.
        let origin = baseURL.lowercased().hasPrefix("https:") ? "wss" + baseURL.dropFirst(5) : "ws" + baseURL.dropFirst(4)
        return "\(origin)/conversations/\(encodeComponent(session.conversationId))/ws?role=user&token=\(encodeComponent(token))"
    }

    /// Uses `session` and opens the socket, returning once it is open. Fails with a typed error (no automatic retry
    /// for this first attempt); after it has opened once, a dropped socket is retried with backoff by the client.
    func connect(_ session: GiovSession) async throws {
        // Messages already waiting in the outbox are kept: they go out on this socket.
        teardown()
        desired = true
        currentSession = session
        attempt = 0
        try await open(generation)
    }

    private func open(_ generation: Int) async throws {
        guard desired, currentSession != nil, generation == self.generation else { return }
        let token = try await self.token(force: true).token
        guard desired, generation == self.generation, let session = currentSession else { throw GiovChatError.disconnected() }
        let link = SocketLink(client: self, generation: generation)
        link.start(url: socketURL(session, token: token))
        cancelHandshake = { [weak link] in link?.finish(.disconnected()) }
        try await link.done.wait()
    }

    /// One socket's callbacks and timers.
    @MainActor
    private final class SocketLink: GiovSocketListener {
        let done = Completion()
        private weak var client: GiovChatClient?
        let generation: Int
        private(set) var socket: (any GiovSocket)?
        private var opened = false
        private var openTimer: Task<Void, Never>?
        var pongDeadline: Task<Void, Never>?

        init(client: GiovChatClient, generation: Int) {
            self.client = client
            self.generation = generation
        }

        func start(url: String) {
            guard let client else { return }
            let clock = client.clock
            openTimer = Task { @MainActor [weak self] in
                do { try await clock.sleep(ms: socketOpenTimeoutMs) } catch { return }
                guard let self else { return }
                self.finish(.network("Chat connection timed out.", timedOut: true))
                self.drop()
            }
            let socket = client.socketFactory.makeSocket(url: url, listener: self)
            self.socket = socket
            client.socket = socket
        }

        func finish(_ error: GiovChatError? = nil) {
            guard !done.isCompleted else { return }
            openTimer?.cancel()
            done.complete(error)
        }

        private var current: Bool {
            guard let client, let socket else { return false }
            return generation == client.generation && client.socket === socket
        }

        func drop() {
            socket?.close(code: nil, reason: nil)
            closed(code: nil, reason: nil)
        }

        // Callbacks are handled in a later main-actor turn, in order, as the protocol client expects (a reply that a
        // socket delivers inside send() is handled after the send).
        func socketDidOpen() {
            Task { self.handleOpen() }
        }

        func socketDidReceive(_ text: String) {
            Task { self.handleMessage(text) }
        }

        func socketDidClose(code: Int?, reason: String?) {
            Task { self.closed(code: code, reason: reason) }
        }

        func socketDidFail(_ error: Error, httpStatus: Int?) {
            let description = String(describing: error)
            Task {
                // Only the HTTP status of the refused upgrade is looked at, never the error text.
                if httpStatus == 410 {
                    self.finish(.conversationClosed(status: 410))
                    self.closed(code: 1000, reason: deletedReason)
                } else {
                    self.finish(GiovChatError(.network, "Unable to connect to chat.", underlying: description))
                    self.closed(code: nil, reason: nil)
                }
            }
        }

        private func handleOpen() {
            guard let client, let socket else { return }
            if generation != client.generation || !client.desired || done.isCompleted || !current {
                socket.close(code: nil, reason: nil)
                return
            }
            opened = true
            client.attempt = 0
            client.dropSocket = { [weak self] in self?.drop() }
            client.events?.connection(true)
            let clock = client.clock
            // A ping every 25 s; no pong within 10 s means the socket is dead.
            client.heartbeat = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await clock.sleep(ms: socketPingIntervalMs) } catch { return }
                    guard let self, let socket = self.socket else { return }
                    // The socket holds this link strongly, so a client released without disconnecting (its
                    // controller was dropped without close()) would otherwise keep pinging, and suppressing
                    // pushes, for ever.
                    guard self.current else {
                        socket.close(code: nil, reason: nil)
                        return
                    }
                    if !socket.send(pingFrame) {
                        self.drop()
                        return
                    }
                    self.pongDeadline?.cancel()
                    self.pongDeadline = Task { @MainActor [weak self] in
                        do { try await clock.sleep(ms: socketPongTimeoutMs) } catch { return }
                        self?.drop()
                    }
                }
            }
            // A message on a socket that never answered means the socket is dead: reconnect and resend.
            client.watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await clock.sleep(ms: watchdogIntervalMs) } catch { return }
                    guard let self, let client = self.client else { return }
                    if client.outbox.stale(now: clock.now()) { self.drop() }
                }
            }
            finish()
            if client.flushOnOpen { client.flush() }
        }

        private func handleMessage(_ text: String) {
            if client == nil {
                // Nobody is listening any more (see the heartbeat).
                socket?.close(code: nil, reason: nil)
                return
            }
            guard current, let client, let data = JSONValue.parse(text)?.objectValue else { return }
            client.receive(data) { [weak self] in
                self?.pongDeadline?.cancel()
                self?.pongDeadline = nil
            }
        }

        func closed(code: Int?, reason: String?) {
            pongDeadline?.cancel()
            guard current, let client else { return }
            client.socket = nil
            client.dropSocket = nil
            client.outbox.socketClosed()
            client.heartbeat?.cancel()
            client.watchdog?.cancel()
            client.heartbeat = nil
            client.watchdog = nil
            client.events?.connection(false)
            finish(.network("Chat connection closed."))
            if code == 1000 && reason == deletedReason {
                // The conversation is gone: no reconnect; the owner forgets the stored session.
                client.desired = false
                client.events?.error(.conversationClosed())
                return
            }
            if opened { client.reconnect(generation) }
        }
    }

    private func receive(_ data: [String: JSONValue], pong: () -> Void) {
        let type = data.at("type").string
        if type == "pong" {
            pong()
            return
        }
        if type == "typing" || type == "typing_end" {
            if data.at("role").string == "agent" {
                // `typing_end` keeps its `isBot` too: a person's end must not hide the bot's indicator.
                events?.typing(type == "typing", data.at("isBot").bool)
            }
            return
        }
        let streamId = data.at("streamId").string
        if type == "stream", let streamId {
            events?.stream(.update(streamId: streamId, content: data.at("content").string ?? ""))
            return
        }
        if type == "stream_end", let streamId {
            events?.stream(.end(streamId: streamId))
            return
        }
        if type == "error" {
            serverError(data)
            return
        }
        let clientMessageId = data.at("clientMessageId").string
        if type == "message_ack", let clientMessageId {
            var stored = data.at("message").object
            stored["role"] = .string("visitor")
            let message = GiovMessage.fromJSON(.object(stored))
            outbox.acknowledge(clientMessageId)
            if let message { events?.ack(clientMessageId, message) }
            return
        }
        // Unknown frame types are ignored (protocol versioning).
        if type != nil && type != "message" { return }
        guard var message = GiovMessage.fromJSON(.object(data)) else { return }
        // The saved reply takes the place of its streamed draft, under the draft's key so it is not redrawn.
        if let streamId { message.clientMessageId = "stream:\(streamId)" }
        events?.message(message)
        if let streamId { events?.stream(.end(streamId: streamId)) }
    }

    /// Error frames: a save failure names its message; refusals and rate limits apply to what is on the socket.
    private func serverError(_ data: [String: JSONValue]) {
        let socket = self.socket
        let id = data.at("clientMessageId").string
        let error = data.at("error").string
        if error == "message_failed", let id {
            guard let outcome = outbox.rejected(id) else { return }
            if outcome.failed {
                events?.error(.sendFailed("Message could not be sent. Please try again.", code: "message_failed"))
            } else {
                later(outcome.retryAfterMs) { [weak self] in
                    guard let self, self.socket === socket else { return }
                    self.flush()
                }
            }
            return
        }
        if error == "rate_limited" {
            // Too fast: everything on the socket goes again a little later, with the same ids.
            outbox.socketClosed()
            later(rateLimitPauseMs) { [weak self] in
                guard let self, self.socket === socket else { return }
                self.flush()
            }
            return
        }
        // `invalid_message`, `invalid_attachment`, and any code this version does not know: the asyncapi document says
        // to treat an unknown one as `invalid_message`. Ignoring it left the message "sending" until the ack watchdog
        // dropped the socket, and the resend was refused again, for ever.
        guard let error, error != "message_failed" else { return }
        // Frames are checked in order, so the refusal is for the oldest message still waiting.
        outbox.refuseOldestSending()
        events?.error(.sendFailed("Message could not be sent. Please try again.", code: error))
    }

    private func later(_ delayMs: Int, _ run: @escaping @MainActor () -> Void) {
        let id = nextResend
        nextResend += 1
        let clock = self.clock
        resendTasks[id] = Task { @MainActor [weak self] in
            do { try await clock.sleep(ms: delayMs) } catch { return }
            self?.resendTasks[id] = nil
            run()
        }
    }

    private func reconnect(_ generation: Int) {
        guard desired, generation == self.generation, reconnectTask == nil else { return }
        let wait = giovReconnectDelayMs(attempt: attempt, jitter: random())
        attempt += 1
        let clock = self.clock
        reconnectTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(ms: wait) } catch { return }
            guard let self else { return }
            self.reconnectTask = nil
            self.retryOpen(generation)
        }
    }

    private func retryOpen(_ generation: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.open(generation)
            } catch {
                guard self.desired, generation == self.generation, !(error is CancellationError) else { return }
                let failure = error.asGiovError
                if failure.kind == .sessionExpired { self.disconnect() } else { self.reconnect(generation) }
                self.events?.error(failure)
            }
        }
    }

    /// Reconnect now instead of waiting for the backoff, e.g. when the network comes back.
    func reconnectNow() {
        guard desired, !isConnected, let task = reconnectTask else { return }
        task.cancel()
        reconnectTask = nil
        attempt = 0
        retryOpen(generation)
    }

    /// Puts everything waiting in the outbox on the socket, oldest first.
    func flush() {
        guard let socket, socket.isOpen else { return }
        for item in outbox.takeQueued(now: clock.now()) {
            if !socket.send(item.frame) {
                dropSocket?()
                return
            }
        }
    }

    /// Queues a visitor message and sends it as soon as a socket is open; returns its client message id at once.
    /// Delivery is tracked in the outbox and confirmed through `ClientEvents.ack`. Throws `sendFailed` for an empty or
    /// over-long message.
    @discardableResult
    func send(_ text: String, attachments: [String] = []) throws(GiovChatError) -> String {
        let entry = try outbox.enqueue(text, attachments: attachments, now: clock.now())
        flush()
        return entry.clientMessageId
    }

    /// Sends a message that failed again, in its original place in the queue.
    @discardableResult
    func retryMessage(_ clientMessageId: String) -> Bool {
        let retried = outbox.retry(clientMessageId)
        if retried { flush() }
        return retried
    }

    /// The visitor started typing (send once per burst).
    func sendTyping() { sendFrame(#"{"type":"typing"}"#) }

    func sendTypingEnd() { sendFrame(#"{"type":"typing_end"}"#) }

    private func sendFrame(_ frame: String) {
        guard let socket, socket.isOpen else { return }
        _ = socket.send(frame) // A failure is recovered by the next reconnect.
    }

    // MARK: - Uploads and push

    /// Uploads one file to this conversation and returns its URL for `send`. `onProgress` gets 0 to 1 as the bytes
    /// leave the device. Retries once with a new token on 401. Throws `attachmentRejected` when the server refuses
    /// the file, `conversationClosed` (404) when the conversation is gone, `sessionExpired` on a second 401 / 403,
    /// `rateLimited` on 429, `server` on 5xx and `network` when nothing came back.
    ///
    /// The whole exchange (token renewal, the upload and its retry) is bounded by ``uploadTimeoutMs``: a stalled
    /// network ends in a timed-out ``GiovChatError/Kind/network`` failure instead of an upload that never finishes.
    func uploadAttachment(_ file: GiovPickedFile, onProgress: ((Double) -> Void)? = nil) async throws -> GiovUploadResult {
        let url = try baseURL + conversationPath() + "/upload-visitor"
        let gate = ProgressGate(onProgress)
        defer { gate.close() }
        do {
            return try await giovWithTimeout(uploadTimeoutMs, clock: clock) { @MainActor [self] in
                try await self.uploadExchange(url: url, file: file, gate: gate)
            }
        } catch is TimedOut {
            throw GiovChatError.network("File upload timed out.", timedOut: true)
        }
    }

    private func uploadExchange(url: String, file: GiovPickedFile, gate: ProgressGate) async throws -> GiovUploadResult {
        var token = try await self.token().token
        var reply = await upload(url, token: token, file: file, gate: gate)
        if reply.status == 401 {
            token = try await self.token(force: true).token
            reply = await upload(url, token: token, file: file, gate: gate)
        }
        guard reply.ok, let uploaded = reply.body.at("url").string else {
            let message = reply.body.at("message").string ?? reply.code ?? "File upload failed."
            if Task.isCancelled { throw CancellationError() }
            if reply.status == 401 || reply.status == 403 { throw GiovChatError.sessionExpired(message, status: reply.status, code: reply.code) }
            if reply.status == 0 { throw GiovChatError.network(message) }
            // Only a refusal of the file itself is an attachment rejection; the route also answers 404 for a
            // conversation that is gone, 429 when rate limited and 5xx, which mean what they mean everywhere else.
            if reply.status == 404 { throw GiovChatError.conversationClosed(message, status: 404, code: reply.code) }
            if reply.status == 429 || reply.status >= 500 { throw failure(reply) }
            throw GiovChatError.attachmentRejected(message, status: reply.status, code: reply.code)
        }
        if let access = GiovAttachmentAccess.fromJSON(reply.body["attachmentAccess"]) { events?.attachmentAccess(access) }
        return GiovUploadResult(
            url: uploaded,
            filename: reply.body.at("filename").string ?? file.name,
            preview: GiovAttachmentPreview.sanitize(reply.body["preview"])
        )
    }

    private func upload(_ url: String, token: String, file: GiovPickedFile, gate: ProgressGate) async -> Reply {
        let preview = uploadPreview(file)
        let body = GiovUploadBody(file: file, thumbnail: preview?.thumb, width: preview?.width, height: preview?.height) { value in
            Task { @MainActor in gate.report(value) }
        }
        let request = GiovHTTPRequest(method: "POST", url: url, headers: ["Authorization": "Bearer \(token)"], upload: body)
        let http = self.http
        do {
            let response = try await giovWithTimeout(uploadTimeoutMs, clock: clock) { try await http.send(request) }
            let parsed = reply(response)
            if parsed.ok { gate.report(1) }
            return parsed
        } catch {
            return Reply(status: 0, body: [:], retryAfterSeconds: 0)
        }
    }

    /// Registers this device for visitor push notifications about this conversation (README, "Push notifications").
    /// Never throws: a server without visitor push answers 404/405/501, after which the client stops asking and
    /// reports `unsupported`.
    func registerPushToken(_ token: String, platform: GiovPushPlatform, options: GiovPushOptions = GiovPushOptions()) async -> GiovPushResult {
        if pushUnsupported { return .notRegistered(.unsupported) }
        guard let path = try? conversationPath() else { return .notRegistered(.noConversation) }
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.count > 4096 { return .notRegistered(.failed) }
        var body: [String: JSONValue] = ["token": .string(token), "platform": .string(platform.rawValue)]
        if let environment = options.environment { body["environment"] = .string(environment.rawValue) }
        if let appId = options.appId, !appId.isEmpty { body["appId"] = .string(appId) }
        if let locale = options.locale ?? locale { body["locale"] = .string(locale) }
        do {
            // The server stores the client marker with the device (visitor-api.openapi.yaml, registerPushToken).
            let reply = try await authed("POST", path + "/push-token", headers: ["X-Giov-Client": clientMarker], json: body)
            if [404, 405, 501].contains(reply.status) {
                pushUnsupported = true
                return .notRegistered(.unsupported)
            }
            return reply.ok ? .registered : .notRegistered(.failed)
        } catch {
            return .notRegistered(.failed)
        }
    }

    /// Stops push notifications about this conversation on this device (sign-out, notifications off). Never throws;
    /// true when the server confirmed. Without a connection it uses `session` (the stored pair) for a fresh visitor
    /// token.
    func unregisterPushToken(_ token: String, session: GiovSession? = nil) async -> Bool {
        guard !pushUnsupported, !token.isEmpty, let target = currentSession ?? session else { return false }
        let body: [String: JSONValue] = ["token": .string(token)]
        do {
            if currentSession != nil {
                return try await authed("DELETE", try conversationPath() + "/push-token", json: body).ok
            }
            let visitor = try await fetchToken(target)
            let path = "/conversations/\(encodeComponent(target.conversationId))/push-token"
            return try await request("DELETE", path, headers: ["Authorization": "Bearer \(visitor.token)"], json: body).ok
        } catch {
            return false
        }
    }

    // MARK: - Teardown

    /// Closes the connection. Unsent messages stay in the outbox.
    func disconnect() {
        teardown()
    }

    private func teardown() {
        desired = false
        generation += 1
        reconnectTask?.cancel()
        heartbeat?.cancel()
        watchdog?.cancel()
        for task in resendTasks.values { task.cancel() }
        resendTasks.removeAll()
        reconnectTask = nil
        heartbeat = nil
        watchdog = nil
        dropSocket = nil
        cancelHandshake?()
        cancelHandshake = nil
        let old = socket
        socket = nil
        old?.close(code: nil, reason: nil)
        // Unsent messages stay in the outbox; a later connection sends them.
        outbox.socketClosed()
        currentSession = nil
        currentToken = nil
        tokenRequest?.task.cancel()
        tokenRequest = nil
        events?.connection(false)
    }

    /// Disconnects and stops reporting. The client cannot be used afterwards.
    func dispose() {
        if disposed { return }
        disposed = true
        disconnect()
        events = nil
    }
}

/// A one-shot result that several tasks can wait for.
@MainActor
final class Completion {
    private var result: Result<Void, GiovChatError>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var isCompleted: Bool { result != nil }

    func complete(_ error: GiovChatError?) {
        guard result == nil else { return }
        let value: Result<Void, GiovChatError> = error.map { .failure($0) } ?? .success(())
        result = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: value.mapError { $0 as Error }) }
    }

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let result {
                continuation.resume(with: result.mapError { $0 as Error })
            } else {
                waiters.append(continuation)
            }
        }
    }
}

/// Forwards upload progress until the upload has finished, never going backwards.
@MainActor
private final class ProgressGate {
    private var handler: ((Double) -> Void)?
    private var last = -1.0

    init(_ handler: ((Double) -> Void)?) {
        self.handler = handler
    }

    func report(_ value: Double) {
        guard let handler, value >= last else { return }
        last = value
        handler(min(max(value, 0), 1))
    }

    func close() {
        handler = nil
    }
}
