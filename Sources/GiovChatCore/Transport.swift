import Foundation

// The seams the client talks to: HTTP, the conversation socket and time. Production defaults use URLSession and
// Task.sleep; tests (and apps with special needs, such as certificate pinning) supply their own.

// MARK: - HTTP

/// A file upload: `multipart/form-data` with the file and, for images, the placeholder fields.
public struct GiovUploadBody: Sendable {
    public var file: GiovPickedFile
    public var thumbnail: String?
    public var width: Int?
    public var height: Int?
    /// Called with 0...1 as the bytes leave the device, on any thread.
    public var onProgress: (@Sendable (Double) -> Void)?

    public init(file: GiovPickedFile, thumbnail: String? = nil, width: Int? = nil, height: Int? = nil, onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.file = file
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
        self.onProgress = onProgress
    }
}

/// One HTTP request. ``jsonBody`` and ``upload`` are mutually exclusive.
public struct GiovHTTPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var jsonBody: String?
    public var upload: GiovUploadBody?

    public init(method: String, url: String, headers: [String: String] = [:], jsonBody: String? = nil, upload: GiovUploadBody? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.jsonBody = jsonBody
        self.upload = upload
    }
}

/// The answer: status, body and the headers with lower-case names.
public struct GiovHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public init(status: Int, text: String, headers: [String: String] = [:]) {
        self.init(status: status, body: Data(text.utf8), headers: headers)
    }
}

/// Sends one request. Throws when the server cannot be reached; any HTTP status is a normal response. Must honour
/// task cancellation (the client cancels requests that time out).
public protocol GiovHTTP: Sendable {
    func send(_ request: GiovHTTPRequest) async throws -> GiovHTTPResponse
}

// MARK: - Socket

/// Callbacks of one socket. Implementations of ``GiovSocket`` call them on the main actor, one at a time and in
/// order.
@MainActor
public protocol GiovSocketListener: AnyObject {
    /// The upgrade succeeded.
    func socketDidOpen()
    /// A text frame.
    func socketDidReceive(_ text: String)
    /// The socket is finished. Close code `1000` with reason `Conversation deleted` means the conversation is gone
    /// (docs/protocol/README.md, "Connecting"). `code` is nil when the connection dropped without a close frame.
    func socketDidClose(code: Int?, reason: String?)
    /// The connection failed or broke; this is terminal (no close callback follows). `httpStatus` is the status of a
    /// refused upgrade: only `410` means the conversation was deleted.
    func socketDidFail(_ error: Error, httpStatus: Int?)
}

/// One conversation socket. Used on the main actor.
@MainActor
public protocol GiovSocket: AnyObject {
    /// True between the upgrade and the first close or failure.
    var isOpen: Bool { get }
    /// Queues `frame`; false when the socket is closing or closed.
    func send(_ frame: String) -> Bool
    /// Closes the socket; no callback follows for a close the client asked for.
    func close(code: Int?, reason: String?)
}

/// Creates a socket for `ws(s)://.../conversations/{id}/ws?role=user&token=...` and starts connecting at once. The
/// socket holds its listener strongly until it finishes.
public protocol GiovSocketFactory: Sendable {
    @MainActor
    func makeSocket(url: String, listener: any GiovSocketListener) -> any GiovSocket
}

// MARK: - Time

/// Wall-clock time and cancellable waits.
public protocol GiovClock: Sendable {
    /// Unix milliseconds.
    func now() -> Int
    /// Waits `ms` milliseconds. Throws `CancellationError` when the calling task is cancelled.
    func sleep(ms: Int) async throws
}

/// The system clock: `Date()` and `Task.sleep`.
public struct GiovSystemClock: GiovClock {
    public init() {}

    public func now() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded()) }

    public func sleep(ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }
}

// MARK: - URLs

/// The API origin the SDK talks to unless told otherwise.
public let giovDefaultBaseURL = "https://api.giovchat.app"

/// The base URL was not an HTTP(S) URL without credentials, query or fragment.
public struct GiovInvalidBaseURL: Error, Sendable, Equatable {
    public let value: String
}

/// Validates the API base URL and removes trailing slashes.
func normalizeBaseURL(_ value: String) throws(GiovInvalidBaseURL) -> String {
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.percentEncodedQuery == nil, components.percentEncodedFragment == nil
    else { throw GiovInvalidBaseURL(value: value) }
    var trimmed = value
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed
}

private let componentAllowed: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
    return set
}()

/// Percent-encodes everything but `A-Z a-z 0-9 - . _ *` (a space is `%20`).
func encodeComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? value
}
