import Foundation

// Visitor messages the server has not acknowledged yet, in the order they were written. Every message keeps one
// client message id for its whole life, so resending after a dropped socket can never store it twice: the server
// answers a repeat with the original's ack (docs/protocol/README.md, "Outbox and idempotency"). Pure: no sockets
// or timers, so the rules are testable on their own.

/// `queued`: waiting for a socket. `sending`: on a socket, no ack yet. `failed`: the visitor must retry or discard.
enum OutboxState: Sendable, Equatable {
    case queued, sending, failed
}

struct OutboxEntry: Sendable, Equatable {
    let clientMessageId: String
    let content: String
    /// Uploaded attachment URLs this message carries.
    let attachments: [String]
    /// Unix milliseconds.
    let createdAt: Int
    var state: OutboxState = .queued
    /// When it last went out on a socket (Unix ms); 0 while it is waiting for one.
    var sentAt: Int = 0
    /// Times the server said it could not save it.
    var failures: Int = 0
}

/// A sent message with no ack after this long means a dead socket: reconnect and resend.
let ackTimeoutMs = 10_000
/// Save failures retried before the visitor is told the message did not send.
let maxSendFailures = 3
let maxMessageChars = 2000

/// Wait before resending after a save failure: 2 s, 4 s, ...
func sendRetryDelayMs(_ failures: Int) -> Int { 2000 * failures }

struct OutboxFrame: Sendable, Equatable {
    let clientMessageId: String
    let frame: String
}

struct OutboxRejection: Sendable, Equatable {
    /// True once the message gave up; the visitor decides.
    let failed: Bool
    let retryAfterMs: Int
}

final class Outbox {
    private var entries: [OutboxEntry] = []
    private var listeners: [Int: () -> Void] = [:]
    private var nextListener = 0
    private let now: () -> Int

    init(now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    /// Calls `listener` after every change; returns the function that stops it.
    func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = nextListener
        nextListener += 1
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    private func changed() {
        for key in listeners.keys.sorted() {
            listeners[key]?()
        }
    }

    private func index(_ clientMessageId: String) -> Int? {
        entries.firstIndex { $0.clientMessageId == clientMessageId }
    }

    /// Copies, oldest first.
    func list() -> [OutboxEntry] { entries }

    subscript(clientMessageId: String) -> OutboxEntry? {
        index(clientMessageId).map { entries[$0] }
    }

    var count: Int { entries.count }

    /// Adds a message at the end. Throws ``GiovChatError/Kind/sendFailed`` when it could never be accepted (empty or
    /// too long).
    @discardableResult
    func enqueue(_ content: String, attachments: [String] = [], now nowMs: Int? = nil, clientMessageId: String? = nil) throws(GiovChatError) -> OutboxEntry {
        let blank = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if (blank && attachments.isEmpty) || content.utf16.count > maxMessageChars {
            throw .sendFailed("Messages must contain 1-2000 characters.")
        }
        let entry = OutboxEntry(
            clientMessageId: clientMessageId ?? randomClientId(),
            content: content,
            attachments: attachments,
            createdAt: nowMs ?? now()
        )
        if let existing = index(entry.clientMessageId) { entries.remove(at: existing) }
        entries.append(entry)
        changed()
        return entry
    }

    /// Everything waiting for a socket, in order, marked as sent now. Failed messages wait for ``retry(_:)``.
    func takeQueued(now nowMs: Int? = nil) -> [OutboxFrame] {
        let time = nowMs ?? now()
        var out: [OutboxFrame] = []
        for index in entries.indices where entries[index].state == .queued {
            entries[index].state = .sending
            entries[index].sentAt = time
            out.append(OutboxFrame(clientMessageId: entries[index].clientMessageId, frame: Outbox.frame(entries[index])))
        }
        if !out.isEmpty { changed() }
        return out
    }

    /// The server saved it: the message leaves the queue. Unknown ids (already acknowledged) return nil.
    @discardableResult
    func acknowledge(_ clientMessageId: String) -> OutboxEntry? {
        guard let index = index(clientMessageId) else { return nil }
        let entry = entries.remove(at: index)
        changed()
        return entry
    }

    /// The server could not save it: wait and resend, or give up after ``maxSendFailures``.
    func rejected(_ clientMessageId: String) -> OutboxRejection? {
        guard let index = index(clientMessageId), entries[index].state != .failed else { return nil }
        entries[index].failures += 1
        entries[index].sentAt = 0
        let failed = entries[index].failures >= maxSendFailures
        entries[index].state = failed ? .failed : .queued
        changed()
        return OutboxRejection(failed: failed, retryAfterMs: failed ? 0 : sendRetryDelayMs(entries[index].failures))
    }

    /// A message the server refused outright (invalid content or attachment): no retry can fix it.
    @discardableResult
    func refuseOldestSending() -> OutboxEntry? {
        guard let index = entries.firstIndex(where: { $0.state == .sending }) else { return nil }
        entries[index].state = .failed
        entries[index].sentAt = 0
        changed()
        return entries[index]
    }

    /// The socket went away: whatever was on it goes out again on the next one, with the same ids.
    func socketClosed() {
        var touched = false
        for index in entries.indices where entries[index].state == .sending {
            entries[index].state = .queued
            entries[index].sentAt = 0
            touched = true
        }
        if touched { changed() }
    }

    /// True when a message has waited longer than ``ackTimeoutMs`` on an open socket.
    func stale(now nowMs: Int? = nil) -> Bool {
        let time = nowMs ?? now()
        return entries.contains { $0.state == .sending && $0.sentAt > 0 && time - $0.sentAt > ackTimeoutMs }
    }

    /// The visitor asked to try a failed message again: it rejoins the queue in its original place.
    @discardableResult
    func retry(_ clientMessageId: String) -> Bool {
        guard let index = index(clientMessageId), entries[index].state == .failed else { return false }
        entries[index].state = .queued
        entries[index].failures = 0
        entries[index].sentAt = 0
        changed()
        return true
    }

    @discardableResult
    func remove(_ clientMessageId: String) -> Bool {
        guard let index = index(clientMessageId) else { return false }
        entries.remove(at: index)
        changed()
        return true
    }

    func clear() {
        if entries.isEmpty { return }
        entries.removeAll()
        changed()
    }

    /// The wire frame; identical every time it is sent.
    static func frame(_ entry: OutboxEntry) -> String {
        var map: [String: JSONValue] = [
            "type": .string("message"),
            "content": .string(entry.content),
            "clientMessageId": .string(entry.clientMessageId),
        ]
        if !entry.attachments.isEmpty { map["attachments"] = .array(entry.attachments.map(JSONValue.string)) }
        return JSONValue.object(map).serialized
    }
}

/// A random (version 4) UUID, made on the device, lowercase.
func randomClientId() -> String { UUID().uuidString.lowercased() }
