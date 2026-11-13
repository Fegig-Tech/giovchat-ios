import Foundation
@testable import GiovChatCore
import Testing

let testSession = GiovSession(conversationId: "conv-1", sessionToken: String(repeating: "b", count: 64))

/// 2026-01-01T00:00:00Z
let epoch = 1_767_225_600_000

// MARK: - JSON from Swift values

func jsonValue(_ value: Any?) -> JSONValue {
    switch value {
    case nil: return .null
    case let value as JSONValue: return value
    case let value as String: return .string(value)
    case let value as Bool: return .bool(value)
    case let value as Int: return .number(Double(value))
    case let value as Double: return .number(value)
    case let value as [String: Any?]: return .object(value.mapValues(jsonValue))
    case let value as [String: Any]: return .object(value.mapValues { jsonValue($0) })
    case let value as [Any?]: return .array(value.map(jsonValue))
    case let value as [Any]: return .array(value.map { jsonValue($0) })
    default: fatalError("unsupported \(String(describing: value))")
    }
}

func json(_ pairs: KeyValuePairs<String, Any?>) -> [String: JSONValue] {
    var map: [String: JSONValue] = [:]
    for (key, value) in pairs { map[key] = jsonValue(value) }
    return map
}

func parse(_ text: String) -> [String: JSONValue] { parseJSONObject(text) }

// MARK: - Virtual time

/// A clock the test moves by hand: `sleep` waits until `advance` passes its due time.
final class ManualClock: GiovClock, @unchecked Sendable {
    private struct Sleeper {
        let due: Int
        let order: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var elapsedMs = 0
    private var sleepers: [Int: Sleeper] = [:]
    private var cancelled: Set<Int> = []
    private var nextId = 0

    var elapsed: Int { lock.sync { elapsedMs } }

    func now() -> Int { epoch + elapsed }

    func sleep(ms: Int) async throws {
        let id: Int = lock.sync {
            nextId += 1
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers[id] = Sleeper(due: elapsedMs + max(ms, 0), order: id, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let sleeper = sleepers.removeValue(forKey: id) {
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelled.insert(id)
                lock.unlock()
            }
        }
    }

    var pendingSleepers: Int { lock.sync { sleepers.count } }

    /// Moves time to the next due sleeper at or before `target`, waking every sleeper due then. False when none is.
    fileprivate func step(upTo target: Int) -> Bool {
        lock.lock()
        guard let due = sleepers.values.map(\.due).filter({ $0 <= target }).min() else {
            elapsedMs = max(elapsedMs, target)
            lock.unlock()
            return false
        }
        elapsedMs = max(elapsedMs, due)
        let ready = sleepers.filter { $0.value.due == due }.sorted { $0.value.order < $1.value.order }
        for (key, _) in ready { sleepers[key] = nil }
        lock.unlock()
        for (_, sleeper) in ready { sleeper.continuation.resume() }
        return true
    }
}

/// Virtual time for a test: a manual clock plus helpers that let queued main-actor work and background hops settle.
@MainActor
class TimeRig {
    let clock: ManualClock

    init(clock: ManualClock = ManualClock()) {
        self.clock = clock
    }

    var now: Int { clock.now() }
    var elapsedMs: Int { clock.elapsed }

    /// Lets everything that is ready now run, a few rounds so chained work (and hops through the global executor)
    /// settles. Waits a few hundred microseconds of real time at most per round.
    func pump(_ rounds: Int = 6) async {
        for _ in 0..<rounds {
            for _ in 0..<10 { await Task.yield() }
            // Blocks the main thread briefly so work hopping through the global executor can queue its way back.
            usleep(100)
        }
        for _ in 0..<10 { await Task.yield() }
    }

    /// Moves virtual time forward by `ms`, running whatever comes due (including what is due exactly at the end).
    func elapse(_ ms: Int) async {
        await pump(3)
        let target = clock.elapsed + ms
        while clock.step(upTo: target) {
            await pump(3)
        }
        await pump(3)
    }

    /// Starts `body` without waiting for it; read ``Pending/value`` later.
    func start<T>(_ body: @escaping @MainActor () async -> T) -> Pending<T> {
        let pending = Pending<T>()
        pending.task = Task { @MainActor in
            pending.value = await body()
        }
        return pending
    }

    /// Starts a throwing `body`; read ``PendingResult/result`` later.
    func startThrowing<T>(_ body: @escaping @MainActor () async throws -> T) -> PendingResult<T> {
        let pending = PendingResult<T>()
        Task { @MainActor in
            do {
                pending.result = .success(try await body())
            } catch {
                pending.result = .failure(error)
            }
        }
        return pending
    }

    /// The error `body` throws, as a GiovChatError (nil when it succeeds).
    func failure(_ body: @MainActor () async throws -> Void) async -> GiovChatError? {
        do {
            try await body()
            return nil
        } catch let error as GiovChatError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }
}

@MainActor
final class Pending<T> {
    var value: T?
    var task: Task<Void, Never>?
    var isCompleted: Bool { value != nil }
}

@MainActor
final class PendingResult<T> {
    var result: Result<T, Error>?

    var error: GiovChatError? {
        if case .failure(let error)? = result { return error as? GiovChatError }
        return nil
    }
}

// MARK: - Fake socket

/// A socket the test drives by hand.
@MainActor
final class FakeSocket: GiovSocket {
    let url: String
    let listener: any GiovSocketListener
    let autoPong: Bool
    var sent: [String] = []
    var open = false
    var closedByClient = false

    init(url: String, listener: any GiovSocketListener, autoPong: Bool) {
        self.url = url
        self.listener = listener
        self.autoPong = autoPong
    }

    var isOpen: Bool { open }

    func send(_ frame: String) -> Bool {
        guard open else { return false }
        sent.append(frame)
        // A real server answers after the ping has left; the client handles it in a later turn either way.
        if autoPong && frame == #"{"type":"ping"}"# { listener.socketDidReceive(#"{"type":"pong"}"#) }
        return true
    }

    func close(code: Int?, reason: String?) {
        closedByClient = true
        open = false
    }

    func accept() {
        open = true
        listener.socketDidOpen()
    }

    func receive(_ pairs: KeyValuePairs<String, Any?>) {
        listener.socketDidReceive(JSONValue.object(json(pairs)).serialized)
    }

    func receiveRaw(_ text: String) {
        listener.socketDidReceive(text)
    }

    /// The server (or network) ended the socket.
    func drop(code: Int? = nil, reason: String? = nil) {
        open = false
        listener.socketDidClose(code: code, reason: reason)
    }

    /// The upgrade was refused (or the connection broke) with `status`.
    func fail(_ status: Int?, message: String = "failed") {
        open = false
        listener.socketDidFail(SocketFailure(description: message), httpStatus: status)
    }

    func frames(_ type: String? = nil) -> [[String: JSONValue]] {
        sent.map(parse).filter { type == nil || $0["type"].string == type }
    }

    func messageFrames() -> [[String: JSONValue]] { frames("message") }

    /// Frame types in order, without pings.
    func types() -> [String?] {
        frames().map { $0["type"].string }.filter { $0 != "ping" }
    }
}

@MainActor
final class Sockets: GiovSocketFactory {
    var all: [FakeSocket] = []
    var autoPong = true
    var last: FakeSocket { all.last! }

    func makeSocket(url: String, listener: any GiovSocketListener) -> any GiovSocket {
        let socket = FakeSocket(url: url, listener: listener, autoPong: autoPong)
        all.append(socket)
        return socket
    }
}

// MARK: - Fake server

struct LoggedRequest {
    let method: String
    let url: String
    let headers: [String: String]
    let json: [String: JSONValue]
    let upload: GiovUploadBody?

    var path: String { URLComponents(string: url)?.path ?? url }
}

/// A small Giov API: config, conversation start/resume, tokens, history, upload and push.
@MainActor
final class FakeServer: GiovHTTP {
    private let clock: ManualClock
    var requests: [LoggedRequest] = []
    var calls: [String: Int] = [:]

    var config: [String: Any?] = [
        "title": "Acme",
        "theme": "light",
        "primaryColor": "#123456",
        "greetingText": "Hi",
        "botEnabled": true,
        "botName": "Atlas",
        "botAvatarUrl": "https://cdn.test/atlas.png",
        "avatarUrl": "https://cdn.test/team.png",
    ]
    var history: [[String: Any?]] = []
    var status = "open"
    var assignedAgentName: String?
    var assignedAgentAvatar: String?

    /// Status codes to answer the next calls with (one per call), before the normal behaviour.
    var historyStatuses: [Int] = []
    var tokenStatuses: [Int] = []
    var uploadStatuses: [Int] = []
    var resumeStatus: Int?
    var resumeError: String?
    var startStatus: Int?
    var startError: String?
    var pushStatus = 200
    var uploadDelayMs = 0
    var resumeDelayMs = 0
    var tokenLifetimeSeconds = 900
    /// Answers for the rating and feedback routes; without one they are unknown routes (an older server).
    var ratingResponder: ((LoggedRequest) -> (status: Int, body: [String: Any?], headers: [String: String]))?
    var feedbackResponder: ((LoggedRequest) -> (status: Int, body: [String: Any?], headers: [String: String]))?

    init(clock: ManualClock) {
        self.clock = clock
    }

    func count(_ key: String) -> Int { calls[key] ?? 0 }

    func to(_ path: String, _ method: String? = nil) -> [LoggedRequest] {
        requests.filter { $0.path == path && (method == nil || $0.method == method) }
    }

    private func reply(_ body: [String: Any?], _ status: Int = 200, headers: [String: String] = [:]) -> GiovHTTPResponse {
        GiovHTTPResponse(status: status, text: jsonValue(body).serialized, headers: headers)
    }

    private func bump(_ key: String) {
        calls[key] = count(key) + 1
    }

    func send(_ request: GiovHTTPRequest) async throws -> GiovHTTPResponse {
        let body = request.jsonBody.map(parse) ?? [:]
        let logged = LoggedRequest(method: request.method, url: request.url, headers: request.headers, json: body, upload: request.upload)
        requests.append(logged)
        let path = logged.path
        if path == "/widget/config" {
            bump("config")
            return reply(config)
        }
        if path == "/conversations" && request.method == "POST" {
            if body["conversationId"] != nil {
                bump("resumed")
                if resumeDelayMs > 0 { try await clock.sleep(ms: resumeDelayMs) }
                if let resumeStatus { return reply(["error": resumeError ?? "invalid_session"], resumeStatus) }
                return reply(["conversationId": testSession.conversationId, "sessionToken": testSession.sessionToken])
            }
            bump("created")
            if let startStatus {
                return reply(["error": startError ?? "workspace_busy"], startStatus, headers: startStatus == 503 ? ["retry-after": "30"] : [:])
            }
            return reply([
                "conversationId": testSession.conversationId,
                "sessionToken": testSession.sessionToken,
                "wsUrl": "wss://api.example.test/conversations/conv-1/ws",
            ])
        }
        if path == "/auth/widget-token" {
            bump("token")
            if !tokenStatuses.isEmpty { return reply(["error": "invalid_session"], tokenStatuses.removeFirst()) }
            return reply([
                "token": "visitor-token-\(count("token"))",
                "expiresAt": clock.now() / 1000 + tokenLifetimeSeconds,
                "attachmentAccess": ["token": "access-token-abcdefgh", "expiresAt": clock.now() + 3_600_000] as [String: Any?],
            ])
        }
        if path.hasSuffix("/history") {
            bump("history")
            if !historyStatuses.isEmpty { return reply(["error": "unauthorized"], historyStatuses.removeFirst()) }
            return reply([
                "status": status,
                "messages": history.map { jsonValue($0) },
                "assignedAgentName": assignedAgentName,
                "assignedAgentAvatar": assignedAgentAvatar,
            ])
        }
        if path.hasSuffix("/upload-visitor") {
            bump("upload")
            request.upload?.onProgress?(0.5)
            if uploadDelayMs > 0 { try await clock.sleep(ms: uploadDelayMs) }
            if !uploadStatuses.isEmpty { return reply(["error": "invalid_token"], uploadStatuses.removeFirst()) }
            let name = request.upload?.file.name ?? "a.png"
            return reply(["url": "https://api.example.test/conversations/conv-1/attachments/\(name)", "filename": name])
        }
        if path.hasSuffix("/rating") && request.method == "POST" {
            bump("rating")
            guard let ratingResponder else { return reply(["error": "not_found"], 404) }
            let answer = ratingResponder(logged)
            return reply(answer.body, answer.status, headers: answer.headers)
        }
        if path.hasSuffix("/feedback") && request.method == "POST" {
            bump("feedback")
            guard let feedbackResponder else { return reply(["error": "not_found"], 404) }
            let answer = feedbackResponder(logged)
            return reply(answer.body, answer.status, headers: answer.headers)
        }
        if path.hasSuffix("/push-token") {
            bump("push-\(request.method)")
            return pushStatus == 200 ? reply(["registered": true]) : reply(["error": "not_found"], pushStatus)
        }
        return reply(["error": "not_found"], 404)
    }
}

// MARK: - Stores

/// A session store that records what happens.
@MainActor
class RecordingStore: GiovSessionStore {
    private var sessions: [String: GiovSession] = [:]
    var log: [String] = []

    func read(scope: String) async throws -> GiovSession? { sessions[scope] }

    func write(scope: String, session: GiovSession) async throws {
        log.append("write")
        sessions[scope] = session
    }

    func delete(scope: String) async throws {
        log.append("delete")
        sessions[scope] = nil
    }

    func seed(_ scope: String, _ session: GiovSession) {
        sessions[scope] = session
    }
}

struct KeychainLocked: Error {}

/// A store whose every call fails.
@MainActor
final class BrokenStore: RecordingStore {
    override func read(scope: String) async throws -> GiovSession? { throw KeychainLocked() }
    override func write(scope: String, session: GiovSession) async throws { throw KeychainLocked() }
    override func delete(scope: String) async throws { throw KeychainLocked() }
}

// MARK: - Client events

/// What the client reported, in order.
@MainActor
final class RecordingEvents {
    var messages: [GiovMessage] = []
    var acks: [(String, GiovMessage)] = []
    var streams: [String] = []
    var typing: [String] = []
    var connection: [Bool] = []
    var errors: [GiovChatError] = []
    var access: [GiovAttachmentAccess] = []

    var events: ClientEvents {
        var events = ClientEvents()
        events.message = { [unowned self] in self.messages.append($0) }
        events.ack = { [unowned self] in self.acks.append(($0, $1)) }
        events.stream = { [unowned self] event in
            switch event {
            case .update(let id, let content): self.streams.append("\(id):\(content)")
            case .end(let id): self.streams.append("\(id):end")
            }
        }
        events.typing = { [unowned self] active, isBot in
            self.typing.append("\(active)/\(isBot.map(String.init(describing:)) ?? "nil")")
        }
        events.connection = { [unowned self] in self.connection.append($0) }
        events.error = { [unowned self] in self.errors.append($0) }
        events.attachmentAccess = { [unowned self] in self.access.append($0) }
        return events
    }
}

extension NSLock {
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}