import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GiovChatCore
import Testing

// The production transports (URLSessionGiovHTTP, URLSessionGiovSocket) against a URLProtocol stub and, on Linux, a
// real local WebSocket server (MiniWebSocketServer.swift), instead of the fakes the other suites use.

// MARK: - URLProtocol stub

/// One host's scripted answer and the requests it received.
final class StubRoute: @unchecked Sendable {
    enum Answer {
        case reply(status: Int, headers: [String: String], body: String)
        case failure(URLError.Code)
        /// Never answers (until the task is cancelled).
        case hang
    }

    struct Seen {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var seen: [Seen] = []
    private var stopped = 0

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func next() -> Answer {
        lock.lock()
        defer { lock.unlock() }
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }

    func record(_ request: Seen) {
        lock.lock()
        seen.append(request)
        lock.unlock()
    }

    func noteStopped() {
        lock.lock()
        stopped += 1
        lock.unlock()
    }

    var requests: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var stops: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()
    private let lock = NSLock()
    private var routes: [String: StubRoute] = [:]

    /// A fresh host answering with `answers` (the last one repeats).
    func host(_ answers: [StubRoute.Answer]) -> (base: String, route: StubRoute) {
        let host = "stub-\(UUID().uuidString.lowercased()).example"
        let route = StubRoute(answers)
        lock.lock()
        routes[host] = route
        lock.unlock()
        return ("https://\(host)", route)
    }

    func route(_ host: String?) -> StubRoute? {
        lock.lock()
        defer { lock.unlock() }
        return host.flatMap { routes[$0] }
    }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = StubRegistry.shared.route(url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(&chunk, maxLength: chunk.count)
                if read <= 0 { break }
                body.append(contentsOf: chunk[0..<read])
            }
            stream.close()
        }
        route.record(StubRoute.Seen(method: request.httpMethod ?? "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:], body: body))
        switch route.next() {
        case .reply(let status, let headers, let text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {
        StubRegistry.shared.route(request.url?.host)?.noteStopped()
    }
}

func stubbedHTTP() -> URLSessionGiovHTTP {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSessionGiovHTTP(session: URLSession(configuration: configuration))
}

/// Polls `condition` with short real sleeps.
@MainActor
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// A header value, whatever the case of its name.
func header(_ headers: [String: String], _ name: String) -> String? {
    headers.first { $0.key.lowercased() == name.lowercased() }?.value
}

@MainActor
@Suite struct URLSessionHTTPTests {
    @Test func jsonRequestsCarryHeadersAndBodyAndAnswersKeepStatusBodyAndLowerCaseHeaders() async throws {
        let (base, route) = StubRegistry.shared.host([.reply(status: 201, headers: ["Retry-After": "7", "X-Thing": "a"], body: #"{"ok":true}"#)])
        let http = stubbedHTTP()
        let response = try await http.send(GiovHTTPRequest(
            method: "POST",
            url: base + "/conversations",
            headers: ["Authorization": "Bearer abc", "Content-Type": "application/json"],
            jsonBody: #"{"tenantId":"t"}"#
        ))
        #expect(response.status == 201)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"ok":true}"#)
        #expect(response.headers["retry-after"] == "7")
        #expect(response.headers["x-thing"] == "a")
        let seen = try #require(route.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.url == base + "/conversations")
        #expect(header(seen.headers, "Authorization") == "Bearer abc")
        #expect(header(seen.headers, "Content-Type") == "application/json")
        #expect(String(decoding: seen.body, as: UTF8.self) == #"{"tenantId":"t"}"#)

        _ = try await http.send(GiovHTTPRequest(method: "GET", url: base + "/widget/config?tenantId=t%20x"))
        let get = try #require(route.requests.last)
        #expect(get.method == "GET")
        #expect(get.url == base + "/widget/config?tenantId=t%20x", "the query is sent as encoded")
        #expect(get.body.isEmpty)
    }

    @Test func theClientMarkerAndTypedFailuresHoldOverURLSession() async throws {
        let (base, route) = StubRegistry.shared.host([
            .reply(status: 200, headers: ["Content-Type": "application/json"], body: #"{"title":"Acme","unknownField":{"x":[1,2]}}"#),
            .reply(status: 429, headers: ["Retry-After": " 12 "], body: #"{"error":"rate_limited"}"#),
            .reply(status: 503, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"], body: #"{"error":"workspace_busy"}"#),
            .failure(.notConnectedToInternet),
        ])
        let client = GiovChatClient(
            tenantKey: "ws 1",
            baseURL: base,
            outbox: Outbox(),
            http: stubbedHTTP(),
            socketFactory: URLSessionGiovSocketFactory(),
            clock: GiovSystemClock()
        )
        let config = try await client.fetchWidgetConfig()
        #expect(config.title == "Acme", "unknown fields are ignored")
        let configRequest = try #require(route.requests.first)
        #expect(header(configRequest.headers, "X-Giov-Client") == "ios/\(GiovChatVersion.current)")
        #expect(configRequest.url == base + "/widget/config?tenantId=ws%201")

        let limited = await failure { _ = try await client.startConversation() }
        #expect(limited?.kind == .rateLimited && limited?.retryAfterSeconds == 12)
        #expect(header(try #require(route.requests.last).headers, "X-Giov-Client") == nil, "only the config request names the SDK")
        let busy = await failure { _ = try await client.startConversation() }
        #expect(busy?.kind == .workspaceBusy && busy?.retryAfterSeconds == 30, "a date Retry-After falls back to 30 s")
        let offline = await failure { _ = try await client.startConversation() }
        #expect(offline?.kind == .network)
    }

    @Test func cancellingTheCallingTaskCancelsTheURLSessionTask() async throws {
        let (base, route) = StubRegistry.shared.host([.hang])
        let http = stubbedHTTP()
        let task = Task { try await http.send(GiovHTTPRequest(method: "GET", url: base + "/slow")) }
        #expect(await eventually { !route.requests.isEmpty })
        let started = Date()
        task.cancel()
        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await eventually { route.stops > 0 }, "the URLSession task was stopped")
    }

    @Test func uploadsGoAsMultipartWithTheFileAndThePlaceholderFields() async throws {
        let (base, route) = StubRegistry.shared.host([.reply(status: 200, headers: [:], body: #"{"url":"https://x/y.png","filename":"y.png"}"#)])
        let http = stubbedHTTP()
        let file = GiovPickedFile(name: "photo.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let thumb = "data:image/jpeg;base64,AAAA"
        let response = try await http.send(GiovHTTPRequest(
            method: "POST",
            url: base + "/conversations/c/upload-visitor",
            headers: ["Authorization": "Bearer tok"],
            upload: GiovUploadBody(file: file, thumbnail: thumb, width: 640, height: 480) { _ in }
        ))
        #expect(response.status == 200)
        let seen = try #require(route.requests.first)
        #expect(seen.method == "POST")
        #expect(header(seen.headers, "Authorization") == "Bearer tok")
        let contentType = try #require(header(seen.headers, "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        // FoundationNetworking does not hand an upload task's body to a URLProtocol; the encoding itself is pinned
        // byte for byte in multipartBodyMatchesTheSpec.
        if !seen.body.isEmpty {
            let expected = try GiovMultipart.encode(GiovUploadBody(file: file, thumbnail: thumb, width: 640, height: 480), boundary: boundary)
            #expect(seen.body == expected)
        }
    }

    @Test func multipartBodyMatchesTheSpec() throws {
        let file = GiovPickedFile(name: "my \"cv\"\r\n.pdf", mimeType: "application/pdf", data: Data("PDF".utf8))
        let plain = try GiovMultipart.encode(GiovUploadBody(file: file), boundary: "B")
        #expect(String(decoding: plain, as: UTF8.self) == [
            "--B",
            #"Content-Disposition: form-data; name="file"; filename="my %22cv%22.pdf""#,
            "Content-Type: application/pdf",
            "",
            "PDF",
            "--B--",
            "",
        ].joined(separator: "\r\n"))

        let image = GiovPickedFile(name: "", mimeType: "", data: Data([1, 2]))
        let withPreview = try GiovMultipart.encode(GiovUploadBody(file: image, thumbnail: "data:image/jpeg;base64,AA==", width: 3, height: 2), boundary: "B")
        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        expected.append(contentsOf: [1, 2])
        expected.append(Data((
            "\r\n--B\r\nContent-Disposition: form-data; name=\"thumbnail\"\r\n\r\ndata:image/jpeg;base64,AA==\r\n" +
                "--B\r\nContent-Disposition: form-data; name=\"width\"\r\n\r\n3\r\n" +
                "--B\r\nContent-Disposition: form-data; name=\"height\"\r\n\r\n2\r\n--B--\r\n"
        ).utf8))
        #expect(withPreview == expected)
    }
}

@MainActor
func failure(_ body: @MainActor () async throws -> Void) async -> GiovChatError? {
    do {
        try await body()
        return nil
    } catch {
        return error as? GiovChatError
    }
}

// MARK: - The real WebSocket

#if canImport(Glibc)
@MainActor
final class SocketRecorder: GiovSocketListener {
    var events: [String] = []

    var terminal: [String] { events.filter { $0.hasPrefix("close") || $0.hasPrefix("fail") } }

    func socketDidOpen() { events.append("open") }
    func socketDidReceive(_ text: String) { events.append("text:\(text)") }
    func socketDidClose(code: Int?, reason: String?) { events.append("close:\(code.map(String.init) ?? "nil"):\(reason ?? "")") }
    func socketDidFail(_ error: Error, httpStatus: Int?) { events.append("fail:\(httpStatus.map(String.init) ?? "nil")") }
}

/// The Swift 6.0 Linux image's FoundationNetworking cannot open WebSockets at all (every task fails at once), so the
/// real-socket tests run with the newer toolchains only.
let realWebSocketsAvailable: Bool = {
    #if compiler(>=6.1)
    return true
    #else
    return false
    #endif
}()

@MainActor
@Suite(.serialized, .enabled(if: realWebSocketsAvailable, "FoundationNetworking in this toolchain has no WebSocket support"))
struct URLSessionSocketTests {
    @Test func theHandshakeHelperIsRight() {
        #expect(webSocketAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func opensReceivesSendsInOrderAndReportsTheServersCloseFrameOnce() async throws {
        let log = ServerLog()
        let server = MiniServer { connection in
            guard let request = connection.readRequest() else { return }
            log.append(String(request.split(separator: "\r\n").first ?? ""))
            connection.upgrade(request)
            connection.sendText(#"{"type":"pong"}"#)
            for _ in 0..<3 {
                guard let text = connection.readText(log: log) else { return }
                log.append(text)
            }
            connection.sendClose(code: 1000, reason: "Conversation deleted")
            _ = connection.readText(log: log)
            usleep(200_000)
        }
        defer { server.stop() }
        let recorder = SocketRecorder()
        let socket = URLSessionGiovSocketFactory().makeSocket(url: server.wsBase + "/conversations/c1/ws?role=user&token=a.b-c", listener: recorder)
        #expect(!socket.isOpen)
        #expect(await eventually { recorder.events.count >= 2 })
        #expect(recorder.events == ["open", #"text:{"type":"pong"}"#])
        #expect(socket.isOpen)
        #expect(socket.send("one"))
        #expect(socket.send("two"))
        #expect(socket.send("three"))
        #expect(await eventually { !recorder.terminal.isEmpty })
        #expect(log.all.prefix(4) == ["GET /conversations/c1/ws?role=user&token=a.b-c HTTP/1.1", "one", "two", "three"])
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(recorder.terminal == ["close:1000:Conversation deleted"], "exactly one terminal callback, the close frame")
        #expect(!socket.isOpen)
        #expect(!socket.send("late"))
    }

    @Test func framesSentBackToBackAllArriveInOrderBeforeTheClose() async throws {
        let server = MiniServer { connection in
            guard let request = connection.readRequest() else { return }
            connection.upgrade(request)
            usleep(100_000)
            for index in 1...3 {
                connection.sendText("f\(index)")
            }
            // FoundationNetworking (Linux) drops data frames that arrive in the same read as a close frame, so the
            // close comes a moment later here. Apple's URLSession is not affected by this test setup.
            usleep(300_000)
            connection.sendClose(code: 1000, reason: "bye")
            usleep(300_000)
        }
        defer { server.stop() }
        let recorder = SocketRecorder()
        let socket = URLSessionGiovSocketFactory().makeSocket(url: server.wsBase + "/ws", listener: recorder)
        #expect(await eventually { !recorder.terminal.isEmpty })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.events == ["open", "text:f1", "text:f2", "text:f3", "close:1000:bye"])
        #expect(!socket.isOpen)
    }

    @Test func aRefusedUpgradeReportsItsStatusOnce() async throws {
        let server = MiniServer { connection in
            guard connection.readRequest() != nil else { return }
            connection.respond("HTTP/1.1 410 Gone\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
            usleep(100_000)
        }
        defer { server.stop() }
        let recorder = SocketRecorder()
        let socket = URLSessionGiovSocketFactory().makeSocket(url: server.wsBase + "/conversations/c1/ws?role=user&token=t", listener: recorder)
        #expect(await eventually { !recorder.terminal.isEmpty })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.events == ["fail:410"])
        #expect(!socket.isOpen)
    }

    @Test func aConnectionThatDropsWithoutACloseFrameEndsOnceWithoutAStatus() async throws {
        let server = MiniServer { connection in
            guard let request = connection.readRequest() else { return }
            connection.upgrade(request)
            usleep(200_000)
        }
        defer { server.stop() }
        let recorder = SocketRecorder()
        let socket = URLSessionGiovSocketFactory().makeSocket(url: server.wsBase + "/ws", listener: recorder)
        #expect(await eventually { !recorder.terminal.isEmpty })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.events.first == "open")
        #expect(recorder.terminal.count == 1)
        #expect(recorder.terminal.first?.hasPrefix("fail:410") == false)
        #expect(!socket.isOpen)
    }

    @Test func closingSendsACloseFrameAndReportsNothing() async throws {
        let log = ServerLog()
        let server = MiniServer { connection in
            guard let request = connection.readRequest() else { return }
            connection.upgrade(request)
            while connection.readText(log: log) != nil {}
        }
        defer { server.stop() }
        let recorder = SocketRecorder()
        let socket = URLSessionGiovSocketFactory().makeSocket(url: server.wsBase + "/ws", listener: recorder)
        #expect(await eventually { recorder.events == ["open"] })
        socket.close(code: nil, reason: nil)
        #expect(!socket.isOpen)
        #expect(!socket.send("after"))
        #expect(await eventually { !log.all.isEmpty })
        #expect(log.all.first == "client-close:1000" || log.all.first == "eof")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.events == ["open"], "no callback for a close the client asked for")
    }

    @Test func aSocketReleasedWithoutClosingEndsItsConnection() async throws {
        let log = ServerLog()
        let server = MiniServer { connection in
            guard let request = connection.readRequest() else { return }
            connection.upgrade(request)
            while connection.readText(log: log) != nil {}
        }
        defer { server.stop() }
        let recorder = SocketRecorder()
        var socket: (any GiovSocket)? = URLSessionGiovSocketFactory().makeSocket(url: server.wsBase + "/ws", listener: recorder)
        #expect(await eventually { recorder.events == ["open"] })
        #expect(socket?.isOpen == true)
        socket = nil
        #expect(await eventually { !log.all.isEmpty }, "the server saw the connection end")
    }

    @Test func theClientRunsItsProtocolOverTheRealSocket() async throws {
        let log = ServerLog()
        let server = MiniServer { connection in
            guard let request = connection.readRequest() else { return }
            log.append(String(request.split(separator: "\r\n").first ?? ""))
            connection.upgrade(request)
            guard let text = connection.readText(log: log) else { return }
            log.append(text)
            let frame = parseJSONObject(text)
            let id = frame["clientMessageId"].string ?? ""
            connection.sendText(#"{"type":"message_ack","clientMessageId":"\#(id)","message":{"id":"m1","role":"visitor","content":"Hello","createdAt":1767225600000,"newField":1}}"#)
            connection.sendText(#"{"type":"future_frame","x":1}"#)
            connection.sendText(#"{"id":"a1","role":"agent","content":"Hi!","createdAt":1767225601000,"senderName":"Ada","senderAvatar":null}"#)
            usleep(300_000) // See framesSentBackToBackAllArriveInOrderBeforeTheClose.
            connection.sendClose(code: 1000, reason: "Conversation deleted")
            _ = connection.readText(log: log)
            usleep(200_000)
        }
        defer { server.stop() }
        let fake = FakeServer(clock: ManualClock())
        let recorded = RecordingEvents()
        let client = GiovChatClient(
            tenantKey: "t",
            baseURL: "http://127.0.0.1:\(server.port)",
            outbox: Outbox(),
            http: fake,
            socketFactory: URLSessionGiovSocketFactory(),
            clock: GiovSystemClock()
        )
        client.events = recorded.events
        defer { client.dispose() }
        try await client.connect(testSession)
        #expect(client.isConnected)
        #expect(log.all.first == "GET /conversations/conv-1/ws?role=user&token=visitor-token-1 HTTP/1.1")
        let id = try client.send("Hello")
        #expect(await eventually { !recorded.errors.isEmpty })
        #expect(recorded.acks.map(\.0) == [id])
        #expect(recorded.acks.first?.1.id == "m1")
        #expect(recorded.messages.map(\.id) == ["a1"])
        #expect(recorded.errors.map(\.kind) == [.conversationClosed], "the close frame means the conversation is gone")
        #expect(recorded.connection.suffix(2) == [true, false])
        #expect(client.outbox.count == 0)
        #expect(!client.isConnected)
    }
}
#endif
