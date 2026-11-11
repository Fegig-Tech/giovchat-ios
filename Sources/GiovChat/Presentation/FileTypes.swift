import Foundation
import GiovChatCore

/// The image type `data` starts with (JPEG, PNG, GIF or WebP), or nil.
func giovSniffImageType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }
    if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
    if bytes.count >= 12, starts(Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
    return nil
}

private let typesByExtension: [String: String] = [
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
    "pdf": "application/pdf", "txt": "text/plain", "csv": "text/csv",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "mp3": "audio/mpeg", "m4a": "audio/mp4", "ogg": "audio/ogg", "oga": "audio/ogg", "weba": "audio/webm",
    "wav": "audio/wav",
]

/// The MIME type of a supported file from its name's extension, else `application/octet-stream` (which the policy
/// check refuses).
func giovMIMEType(forFileName name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "application/octet-stream" }
    let ext = name[name.index(after: dot)...].lowercased()
    return typesByExtension[ext] ?? "application/octet-stream"
}

/// A name for a photo from the library, which has none: `photo-1.jpg`.
func giovPhotoFileName(index: Int, mimeType: String) -> String {
    let ext: String
    switch mimeType {
    case "image/png": ext = "png"
    case "image/gif": ext = "gif"
    case "image/webp": ext = "webp"
    default: ext = "jpg"
    }
    return "photo-\(index + 1).\(ext)"
}
