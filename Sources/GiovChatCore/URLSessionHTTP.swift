import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``GiovHTTP`` over `URLSession`. Uploads go as `multipart/form-data` and report progress as the body is sent.
public final class URLSessionGiovHTTP: GiovHTTP, @unchecked Sendable {
    // URLSession is thread-safe; it is only read after init.
    private let session: URLSession

    /// - Parameter session: the session to use, e.g. one with certificate pinning. Uploads go through it too and
    ///   report progress through a task delegate.
    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func send(_ request: GiovHTTPRequest) async throws -> GiovHTTPResponse {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        if let upload = request.upload {
            let boundary = "giov-" + UUID().uuidString
            let body = try GiovMultipart.encode(upload, boundary: boundary)
            urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            (data, response) = try await uploadWithProgress(urlRequest, body: body, onProgress: upload.onProgress)
        } else {
            if let json = request.jsonBody {
                urlRequest.httpBody = Data(json.utf8)
                if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } else if request.method == "POST" || request.method == "PUT" {
                urlRequest.httpBody = Data()
            }
            (data, response) = try await perform(urlRequest, in: session, upload: nil)
        }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return GiovHTTPResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    }

    private func uploadWithProgress(_ request: URLRequest, body: Data, onProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, URLResponse) {
        guard let onProgress else { return try await perform(request, in: session, upload: body) }
        let delegate = ProgressDelegate(onProgress)
        #if canImport(FoundationNetworking)
        // FoundationNetworking has no per-task delegates: a short-lived session with the same configuration reports
        // the progress and is invalidated (releasing the delegate) once the upload is done.
        let uploadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }
        return try await perform(request, in: uploadSession, upload: body)
        #else
        // A task delegate keeps the app's own session, and so its delegate (certificate pinning, auth challenges),
        // for uploads too; a second session with only the configuration would silently skip the pinning.
        return try await session.upload(for: request, from: body, delegate: delegate)
        #endif
    }

    private func perform(_ request: URLRequest, in session: URLSession, upload: Data?) async throws -> (Data, URLResponse) {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                let task = upload.map { session.uploadTask(with: request, from: $0, completionHandler: completion) }
                    ?? session.dataTask(with: request, completionHandler: completion)
                holder.set(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }
}

/// The running task, so a cancelled Swift task can cancel it.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancel = cancelled
        lock.unlock()
        if cancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1))
    }
}

/// The `multipart/form-data` body of `POST /conversations/{id}/upload-visitor`.
enum GiovMultipart {
    static func encode(_ upload: GiovUploadBody, boundary: String) throws -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        func field(_ name: String, _ value: String) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        let file = upload.file
        let name = file.name.isEmpty ? "file" : file.name
        let safeName = name.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"")
        line("Content-Type: \(file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType)")
        line("")
        body.append(try file.readData())
        line("")
        if let thumbnail = upload.thumbnail, let width = upload.width, let height = upload.height {
            field("thumbnail", thumbnail)
            field("width", String(width))
            field("height", String(height))
        }
        line("--\(boundary)--")
        return body
    }
}
