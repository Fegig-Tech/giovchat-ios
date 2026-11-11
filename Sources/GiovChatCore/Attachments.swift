import Foundation

// Attachments, as the protocol describes them (docs/protocol/README.md, "Attachments"): the server's file limits
// and the answering bot's policy decide what a visitor may send, previews from the network are validated field by
// field, and downloads carry a narrow per-conversation access token.

/// Server limits for attachments.
public enum GiovAttachmentLimits {
    /// The server's upload limit, in bytes.
    public static let maxBytes = 10 * 1024 * 1024
    /// At most this many attachments in one message frame.
    public static let maxFiles = 5
    /// Types `upload-visitor` accepts; a policy wildcard cannot enable anything else.
    public static let supportedTypes: [String] = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "application/pdf", "text/plain", "text/csv",
        "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "audio/mpeg", "audio/mp4", "audio/ogg", "audio/webm", "audio/wav",
    ]
    /// The longest image placeholder (`data:` URI) the server stores.
    public static let maxThumbnailLength = 6000
}

/// What a visitor may attach while GiovBot answers (`GET /widget/config` -> `attachments`).
public struct GiovAttachmentPolicy: Sendable, Equatable {
    public var enabled: Bool
    /// Concrete MIME types (wildcards already expanded against ``GiovAttachmentLimits/supportedTypes``).
    public var allowedTypes: [String]
    public var maxSizeMb: Double

    public init(enabled: Bool, allowedTypes: [String], maxSizeMb: Double) {
        self.enabled = enabled
        self.allowedTypes = allowedTypes
        self.maxSizeMb = maxSizeMb
    }

    /// The largest accepted file, in bytes.
    public var maxBytes: Int { Int(maxSizeMb * 1024 * 1024) }

    /// Without a published bot policy, visitors may send images (the widget's default).
    public static let `default` = GiovAttachmentPolicy(
        enabled: true,
        allowedTypes: GiovAttachmentLimits.supportedTypes.filter { $0.hasPrefix("image/") },
        maxSizeMb: 10
    )

    static func fromJSON(_ json: JSONValue?) -> GiovAttachmentPolicy? {
        guard let raw = json?.objectValue else { return nil }
        let patterns = raw.at("allowedTypes").array.map { $0.compactMap { Optional($0).string?.lowercased() } } ?? GiovAttachmentPolicy.default.allowedTypes
        func matches(_ type: String) -> Bool {
            patterns.contains { pattern in
                pattern == "*" || pattern == type || (pattern.hasSuffix("/*") && type.hasPrefix(String(pattern.dropLast())))
            }
        }
        let size = raw.at("maxSizeMb").number
        return GiovAttachmentPolicy(
            enabled: !raw.at("enabled").isFalse,
            allowedTypes: GiovAttachmentLimits.supportedTypes.filter(matches),
            maxSizeMb: size.map { min(max($0, 0.1), 10) } ?? 10
        )
    }
}

/// A file the host's picker returned: its bytes in memory or a file URL, read when it uploads (once per attempt).
public struct GiovPickedFile: Sendable, Equatable {
    /// Where the bytes are.
    public enum Source: Sendable, Equatable {
        case data(Data)
        case fileURL(URL)
    }

    public var name: String
    /// MIME type, e.g. `image/jpeg`. Files without a known type are refused by the policy check.
    public var mimeType: String
    /// Length in bytes.
    public var size: Int
    public var source: Source
    /// Image size, when known; stored so every viewer sees the shape before the image loads.
    public var width: Int?
    public var height: Int?
    /// Optional placeholder: `data:image/jpeg;base64,...` (or webp), about 32 px, at most 6000 characters. Make one
    /// with `GiovImagePlaceholder` on Apple platforms.
    public var thumbnail: String?

    /// A file whose bytes are already in memory.
    public init(name: String, mimeType: String, data: Data, width: Int? = nil, height: Int? = nil, thumbnail: String? = nil) {
        self.name = name
        self.mimeType = mimeType
        self.size = data.count
        self.source = .data(data)
        self.width = width
        self.height = height
        self.thumbnail = thumbnail
    }

    /// A file on disk; `size` defaults to the file's current length.
    public init(name: String, mimeType: String, fileURL: URL, size: Int? = nil, width: Int? = nil, height: Int? = nil, thumbnail: String? = nil) {
        self.name = name
        self.mimeType = mimeType
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.size = size ?? (attributes?[.size] as? NSNumber)?.intValue ?? 0
        self.source = .fileURL(fileURL)
        self.width = width
        self.height = height
        self.thumbnail = thumbnail
    }

    /// The file's bytes. Throws when a file URL cannot be read.
    public func readData() throws -> Data {
        switch source {
        case .data(let data): return data
        case .fileURL(let url): return try Data(contentsOf: url)
        }
    }
}

/// Why a picked file cannot be sent.
public enum GiovAttachmentProblem: Sendable, Equatable {
    case disabled
    case typeNotAllowed(name: String)
    case tooLarge(name: String, maxSizeMb: Double)
    case tooMany(max: Int)
}

/// The picked files checked against the policy; the server stays authoritative.
public struct GiovAttachmentCheck: Sendable, Equatable {
    public var accepted: [GiovPickedFile]
    public var problems: [GiovAttachmentProblem]
}

/// Checks `files` against `policy` and the server limits; `existingCount` files are already attached.
public func giovValidateAttachments(_ files: [GiovPickedFile], policy: GiovAttachmentPolicy, existingCount: Int = 0) -> GiovAttachmentCheck {
    guard policy.enabled else {
        return GiovAttachmentCheck(accepted: [], problems: files.isEmpty ? [] : [.disabled])
    }
    var accepted: [GiovPickedFile] = []
    var problems: [GiovAttachmentProblem] = []
    let capacity = min(max(GiovAttachmentLimits.maxFiles - existingCount, 0), GiovAttachmentLimits.maxFiles)
    for file in files {
        if !policy.allowedTypes.contains(file.mimeType.lowercased()) {
            problems.append(.typeNotAllowed(name: file.name))
        } else if file.size > policy.maxBytes || file.size > GiovAttachmentLimits.maxBytes {
            problems.append(.tooLarge(name: file.name, maxSizeMb: policy.maxSizeMb))
        } else if accepted.count >= capacity {
            if !problems.contains(where: { if case .tooMany = $0 { return true } else { return false } }) {
                problems.append(.tooMany(max: GiovAttachmentLimits.maxFiles))
            }
        } else {
            accepted.append(file)
        }
    }
    return GiovAttachmentCheck(accepted: accepted, problems: problems)
}

private let thumbPattern = Pattern("^data:image/(jpeg|webp);base64,[A-Za-z0-9+/=]+\\z")

/// A `data:image/jpeg|webp;base64,...` URI of at most 6000 characters.
func isSafeThumbnail(_ value: String?) -> Bool {
    guard let value, value.utf16.count <= GiovAttachmentLimits.maxThumbnailLength else { return false }
    return thumbPattern.matches(value)
}

/// A blurred placeholder for an image while it loads. Every field is validated; unsafe ones are dropped.
public struct GiovAttachmentPreview: Sendable, Equatable {
    /// A `data:image/jpeg|webp;base64,...` URI of at most 6000 characters, or nil.
    public var thumb: String?
    public var width: Int?
    public var height: Int?

    public init(thumb: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.thumb = thumb
        self.width = width
        self.height = height
    }

    /// The Base64 payload of ``thumb``, or nil.
    public var thumbBase64: String? {
        guard let thumb, let comma = thumb.firstIndex(of: ",") else { return nil }
        let payload = String(thumb[thumb.index(after: comma)...])
        return payload.isEmpty ? nil : payload
    }

    /// The decoded placeholder bytes, or nil.
    public var thumbData: Data? { thumbBase64.flatMap { Data(base64Encoded: $0) } }

    /// `width / height`, when both are known.
    public var aspectRatio: Double? {
        guard let width, let height, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// Keeps only the parts of an untrusted preview that are safe to render.
    static func sanitize(_ json: JSONValue?) -> GiovAttachmentPreview? {
        guard let map = json?.objectValue else { return nil }
        let thumb = map.at("thumb").string.flatMap { isSafeThumbnail($0) ? $0 : nil }
        func side(_ value: JSONValue?) -> Int? {
            guard let number = value.number, number > 0, number <= 20000 else { return nil }
            return Int(number)
        }
        let width = side(map["width"])
        let height = side(map["height"])
        // An aspect ratio needs both sides, so a lone dimension is dropped.
        let sized = width != nil && height != nil
        if thumb == nil && !sized { return nil }
        return GiovAttachmentPreview(thumb: thumb, width: sized ? width : nil, height: sized ? height : nil)
    }
}

/// A file attached to a message.
public struct GiovAttachment: Sendable, Equatable {
    /// The download URL without credentials; load it through ``GiovChatController/attachmentURL(_:)``.
    public var url: String
    /// Empty when the server did not say; the UI then names it from the URL (``displayName``).
    public var filename: String
    public var preview: GiovAttachmentPreview?
    /// Known only for files sent from this device.
    public var contentType: String?

    public init(url: String, filename: String = "", preview: GiovAttachmentPreview? = nil, contentType: String? = nil) {
        self.url = url
        self.filename = filename
        self.preview = preview
        self.contentType = contentType
    }

    /// Images render inline; everything else is a file row.
    public var isImage: Bool {
        if let contentType { return contentType.hasPrefix("image/") }
        if preview != nil { return true }
        let name = GiovAttachment.lastSegment(url).lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp"].contains { name.hasSuffix($0) }
    }

    /// A readable name: the known filename, else the last path segment of the URL.
    public var displayName: String { filename.isEmpty ? GiovAttachment.lastSegment(url) : filename }

    static func lastSegment(_ url: String) -> String {
        let path = URLComponents(string: url)?.percentEncodedPath ?? url
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let decoded = last.removingPercentEncoding ?? last
        // Keys look like `attachments/<tenant>/<conversation>/<file>`, URL-encoded into one segment.
        return decoded.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? decoded
    }
}

/// `attachmentId` is a JSON-encoded array of URLs; `previews` is a real array aligned by index.
func parseAttachments(_ attachmentId: JSONValue?, previews: JSONValue? = nil) -> [GiovAttachment] {
    guard let encoded = attachmentId.string, !encoded.isEmpty, let urls = JSONValue.parse(encoded)?.arrayValue else { return [] }
    let list = previews.array
    var out: [GiovAttachment] = []
    for (index, element) in urls.enumerated() {
        guard let url = Optional(element).string, !url.isEmpty else { continue }
        let preview = list.flatMap { index < $0.count ? GiovAttachmentPreview.sanitize($0[index]) : nil }
        out.append(GiovAttachment(url: url, preview: preview))
    }
    return out
}

/// A narrow token for downloading one conversation's files (`?at=`), stable for hours.
public struct GiovAttachmentAccess: Sendable, Equatable, CustomStringConvertible {
    public let token: String
    /// Unix milliseconds (the wire format).
    public let expiresAt: Int

    public init(token: String, expiresAt: Int) {
        self.token = token
        self.expiresAt = expiresAt
    }

    /// True while more than five minutes remain: stop using a token a little before it expires.
    public func usable(at nowMs: Int) -> Bool { expiresAt - nowMs > 5 * 60_000 }

    public var description: String { "GiovAttachmentAccess(expiresAt: \(expiresAt))" }

    private static let pattern = Pattern("^[A-Za-z0-9._-]{16,256}\\z")

    static func fromJSON(_ json: JSONValue?) -> GiovAttachmentAccess? {
        guard let map = json?.objectValue,
              let token = map.at("token").string,
              pattern.matches(token),
              let expiresAt = map.at("expiresAt").int
        else { return nil }
        return GiovAttachmentAccess(token: token, expiresAt: expiresAt)
    }

    /// Keeps the current token unless `incoming` expires no earlier.
    static func newer(_ current: GiovAttachmentAccess?, _ incoming: GiovAttachmentAccess?) -> GiovAttachmentAccess? {
        if let incoming, !(current.map { $0.expiresAt > incoming.expiresAt } ?? false) { return incoming }
        return current
    }
}

/// Adds exactly one credential: `at` when an access token is usable, else the visitor token.
public func giovAttachmentDisplayURL(_ url: String, accessToken: String? = nil, visitorToken: String? = nil) -> String {
    let credential: String
    if let accessToken {
        credential = "at=\(accessToken)"
    } else if let visitorToken {
        credential = "token=\(encodeComponent(visitorToken))"
    } else {
        return url
    }
    return url + (url.contains("?") ? "&" : "?") + credential
}

/// The placeholder fields an upload may carry: all three or none, as the server requires.
struct UploadPreview: Sendable, Equatable {
    let thumb: String
    let width: Int
    let height: Int
}

func uploadPreview(_ file: GiovPickedFile) -> UploadPreview? {
    guard file.mimeType.hasPrefix("image/"),
          let thumb = file.thumbnail, isSafeThumbnail(thumb),
          let width = file.width, (1...20000).contains(width),
          let height = file.height, (1...20000).contains(height)
    else { return nil }
    return UploadPreview(thumb: thumb, width: width, height: height)
}
