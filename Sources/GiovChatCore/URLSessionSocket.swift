import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``GiovSocketFactory`` over `URLSessionWebSocketTask`. The client's own ping/pong runs on top.
public struct URLSessionGiovSocketFactory: GiovSocketFactory {
    public init() {}

    @MainActor
    public func makeSocket(url: String, listener: any GiovSocketListener) -> any GiovSocket {
        URLSessionGiovSocket(url: url, listener: listener)
    }
}

/// One `URLSessionWebSocketTask`. Delegate and receive callbacks are moved to the main actor; exactly one terminal
/// callback (close or failure) is delivered, and none after ``close(code:reason:)``.
@MainActor
final class URLSessionGiovSocket: GiovSocket {
    private var listener: (any GiovSocketListener)?
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private(set) var isOpen = false
    private var finished = false
    /// Frames go out one after another, in the order they were sent (the outbox resends in order).
    private var sendChain: Task<Void, Never>?
    /// The server's close frame, held until the receive loop has delivered the frames before it.
    private var pendingClose: (code: Int, reason: String?)?

    init(url: String, listener: any GiovSocketListener) {
        self.listener = listener
        let delegate = SocketDelegate()
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        if let target = URL(string: url) {
            task = session.webSocketTask(with: target)
        } else {
            task = session.webSocketTask(with: URL(string: "wss://invalid.invalid/")!)
        }
        delegate.socket = WeakSocket(self)
        task.resume()
    }

    deinit {
        // Released without close() (or before the session finished): end the connection and invalidate the session,
        // which otherwise keeps itself, its delegate and an open WebSocket alive for ever.
        if !finished {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }

    func send(_ frame: String) -> Bool {
        guard isOpen, !finished else { return false }
        let task = self.task
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            // A failed send surfaces as a failed receive, which ends the socket.
            try? await task.send(.string(frame))
        }
        return true
    }

    func close(code: Int?, reason: String?) {
        let wasFinished = finished
        finished = true
        isOpen = false
        listener = nil
        if !wasFinished {
            let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code ?? 1000) ?? .normalClosure
            task.cancel(with: closeCode, reason: reason.map { Data($0.utf8) })
        }
        session.finishTasksAndInvalidate()
    }

    fileprivate func didOpen() {
        guard !finished, !isOpen else { return }
        // FoundationNetworking reports a refused upgrade (e.g. `410` for a deleted conversation) as an open; only a
        // `101` is one.
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            ended(error: SocketFailure(description: "upgrade refused"))
            return
        }
        isOpen = true
        listener?.socketDidOpen()
        receiveNext()
    }

    private func receiveNext() {
        let weak = WeakSocket(self)
        let task = self.task
        Task { @MainActor in
            let text: String?
            let failure: String?
            do {
                switch try await task.receive() {
                case .string(let value): text = value
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: text = nil
                }
                failure = nil
            } catch {
                text = nil
                failure = String(describing: error)
            }
            guard let socket = weak.socket else { return }
            if let failure {
                socket.ended(error: SocketFailure(description: failure))
            } else {
                if let text { socket.listener?.socketDidReceive(text) }
                socket.receiveNext()
            }
        }
    }

    /// The delegate saw the server's close frame. While open, the receive loop still has the frames that arrived
    /// before it; it reports the close once they are delivered (otherwise the last messages would be lost).
    fileprivate func serverClosed(code: Int, reason: String?) {
        guard !finished else { return }
        if isOpen {
            pendingClose = (code, reason)
            endSoon(error: nil)
            return
        }
        didClose(code: code, reason: reason)
    }

    /// The delegate saw the task end. While open, the receive loop reports it after the frames before it.
    fileprivate func completed(error: Error?) {
        guard !finished else { return }
        if isOpen {
            endSoon(error: error)
            return
        }
        ended(error: error)
    }

    /// A safety net in case the receive loop does not fail after the task ended: report the end after a moment.
    private func endSoon(error: Error?) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.ended(error: error)
        }
    }

    private func didClose(code: Int, reason: String?) {
        guard !finished else { return }
        finished = true
        isOpen = false
        let listener = self.listener
        self.listener = nil
        session.finishTasksAndInvalidate()
        listener?.socketDidClose(code: code, reason: reason)
    }

    private func ended(error: Error?) {
        guard !finished else { return }
        // A close frame from the server ends the receive loop with an error; report the close instead.
        if let pendingClose {
            didClose(code: pendingClose.code, reason: pendingClose.reason)
            return
        }
        let closeCode = task.closeCode
        if closeCode != .invalid {
            didClose(code: closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) })
            return
        }
        finished = true
        let wasOpen = isOpen
        isOpen = false
        // Only the HTTP status of a refused upgrade is reported, never the error text (it contains the URL).
        let status = wasOpen ? nil : (task.response as? HTTPURLResponse)?.statusCode
        let listener = self.listener
        self.listener = nil
        session.finishTasksAndInvalidate()
        listener?.socketDidFail(error ?? SocketFailure(description: "closed"), httpStatus: status)
    }
}

struct SocketFailure: Error, CustomStringConvertible {
    let description: String
}

private final class WeakSocket: @unchecked Sendable {
    // Read and written on the main actor only.
    weak var socket: URLSessionGiovSocket?

    init(_ socket: URLSessionGiovSocket) {
        self.socket = socket
    }
}

private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    // Set once before the task starts.
    var socket: WeakSocket?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let target = socket
        Task { @MainActor in target?.socket?.didOpen() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let target = socket
        let text = reason.map { String(decoding: $0, as: UTF8.self) }
        let code = closeCode.rawValue
        Task { @MainActor in target?.socket?.serverClosed(code: code, reason: text) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let target = socket
        let description = error.map { String(describing: $0) }
        Task { @MainActor in target?.socket?.completed(error: description.map { SocketFailure(description: $0) }) }
    }
}
