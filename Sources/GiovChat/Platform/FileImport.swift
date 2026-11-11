#if canImport(UniformTypeIdentifiers) && canImport(ImageIO)
import Foundation
import GiovChatCore
import UniformTypeIdentifiers

/// The content types the Files picker offers for the allowed MIME types.
func giovContentTypes(forMIMETypes types: [String]) -> [UTType] {
    let resolved = types.compactMap { UTType(mimeType: $0) }
    return resolved.isEmpty ? [.data] : resolved
}

/// Reads files chosen in the Files picker while their security scope is open. Files over the server's limit are not
/// read; they come back by URL with their size so the policy check refuses them with the right sentence.
func giovReadImportedFiles(_ urls: [URL]) async -> [GiovPickedFile] {
    var files: [GiovPickedFile] = []
    for url in urls {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        let name = values?.name ?? url.lastPathComponent
        let mimeType = values?.contentType?.preferredMIMEType ?? giovMIMEType(forFileName: name)
        let size = values?.fileSize ?? 0
        if size > GiovAttachmentLimits.maxBytes {
            files.append(GiovPickedFile(name: name, mimeType: mimeType, fileURL: url, size: size))
            continue
        }
        guard let data = try? Data(contentsOf: url) else { continue }
        if mimeType.hasPrefix("image/") {
            files.append(GiovPickedFile.image(name: name, mimeType: mimeType, data: data))
        } else {
            files.append(GiovPickedFile(name: name, mimeType: mimeType, data: data))
        }
    }
    return files
}
#endif
