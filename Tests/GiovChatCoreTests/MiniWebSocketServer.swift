#if canImport(Glibc)
import Foundation
import Glibc

// A tiny blocking TCP server for the URLSession transport tests: it speaks just enough HTTP/1.1 and RFC 6455 to
// accept (or refuse) a WebSocket upgrade, exchange text frames and close. One thread per connection; each test
// scripts what the server does with a handler. Linux only (the CI runs the tests there).

/// What the server saw, for the test to read on the main actor.
final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

final class MiniServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let handler: @Sendable (MiniConnection) -> Void

    init(_ handler: @escaping @Sendable (MiniConnection) -> Void) {
        self.handler = handler
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let socketFD = fd
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 16)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    var wsBase: String { "ws://127.0.0.1:\(port)" }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            let connection = MiniConnection(fd: client)
            let handler = self.handler
            Thread {
                handler(connection)
                connection.hangUp()
            }.start()
        }
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        Glibc.close(fd)
    }
}

final class MiniConnection: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var closed = false
    private let lock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        // A test must never hang on a socket: reads give up after 10 s.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func fill(_ count: Int) -> Bool {
        while buffer.count < count {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let read = recv(fd, &chunk, chunk.count, 0)
            if read <= 0 { return false }
            buffer.append(contentsOf: chunk[0..<read])
        }
        return true
    }

    private func take(_ count: Int) -> [UInt8]? {
        guard fill(count) else { return nil }
        let out = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return out
    }

    /// The HTTP request head (request line and headers).
    func readRequest() -> String? {
        let end: [UInt8] = Array("\r\n\r\n".utf8)
        while true {
            if let range = buffer.firstRange(of: end) {
                let head = String(decoding: buffer[0..<range.lowerBound], as: UTF8.self)
                buffer.removeFirst(range.upperBound)
                return head
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let read = recv(fd, &chunk, chunk.count, 0)
            if read <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<read])
        }
    }

    func write(_ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let result = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if result <= 0 { return }
            sent += result
        }
    }

    func respond(_ text: String) { write(Array(text.utf8)) }

    /// Accepts the upgrade in `request`.
    func upgrade(_ request: String) {
        let key = request.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
            .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        respond(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: \(webSocketAccept(key))\r\n\r\n"
        )
    }

    func sendFrame(opcode: UInt8, _ payload: [UInt8]) {
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        write(frame + payload)
    }

    func sendText(_ text: String) { sendFrame(opcode: 0x1, Array(text.utf8)) }

    func sendClose(code: Int, reason: String) {
        sendFrame(opcode: 0x8, [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8))
    }

    /// The next frame from the client (unmasked), or nil at the end of the stream.
    func readFrame() -> (opcode: UInt8, payload: [UInt8])? {
        guard let head = take(2) else { return nil }
        let opcode = head[0] & 0x0F
        let masked = head[1] & 0x80 != 0
        var length = Int(head[1] & 0x7F)
        if length == 126 {
            guard let extended = take(2) else { return nil }
            length = Int(extended[0]) << 8 | Int(extended[1])
        } else if length == 127 {
            guard let extended = take(8) else { return nil }
            length = extended.reduce(0) { $0 << 8 | Int($1) }
        }
        let mask = masked ? take(4) : [0, 0, 0, 0]
        guard let mask, var payload = take(length) else { return nil }
        for index in payload.indices { payload[index] ^= mask[index % 4] }
        return (opcode, payload)
    }

    /// The next text frame; pings are answered, a close frame or the end of the stream returns nil (and logs it).
    func readText(log: ServerLog? = nil) -> String? {
        while let frame = readFrame() {
            switch frame.opcode {
            case 0x1: return String(decoding: frame.payload, as: UTF8.self)
            case 0x9: sendFrame(opcode: 0xA, frame.payload)
            case 0x8:
                let code = frame.payload.count >= 2 ? Int(frame.payload[0]) << 8 | Int(frame.payload[1]) : 0
                log?.append("client-close:\(code)")
                return nil
            default: continue
            }
        }
        log?.append("eof")
        return nil
    }

    func hangUp() {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        closed = true
        shutdown(fd, Int32(SHUT_RDWR))
        Glibc.close(fd)
    }
}

/// `Sec-WebSocket-Accept` for `key` (RFC 6455, section 4.2.2).
func webSocketAccept(_ key: String) -> String {
    Data(sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
}

/// SHA-1 (FIPS 180-4); only for the WebSocket handshake in tests.
func sha1(_ message: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    var bytes = message
    let bitLength = UInt64(message.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xFF)) }
    for chunk in stride(from: 0, to: bytes.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let at = chunk + 4 * i
            w[i] = UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }
        for i in 16..<80 {
            let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
            w[i] = x << 1 | x >> 31
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
        for i in 0..<80 {
            let f: UInt32
            let k: UInt32
            switch i {
            case 0..<20:
                f = (b & c) | (~b & d)
                k = 0x5A82_7999
            case 20..<40:
                f = b ^ c ^ d
                k = 0x6ED9_EBA1
            case 40..<60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1B_BCDC
            default:
                f = b ^ c ^ d
                k = 0xCA62_C1D6
            }
            let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
            e = d
            d = c
            c = b << 30 | b >> 2
            b = a
            a = temp
        }
        h[0] = h[0] &+ a
        h[1] = h[1] &+ b
        h[2] = h[2] &+ c
        h[3] = h[3] &+ d
        h[4] = h[4] &+ e
    }
    return h.flatMap { [UInt8($0 >> 24), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
}
#endif
