#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import GiovChatCore
import ImageIO

/// A decoded picture. Immutable once made, so it can be shared between tasks.
final class GiovDecodedImage: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }

    /// Decodes `data` (with its EXIF orientation applied) to at most `maxPixels` on the long side.
    static func decode(_ data: Data, maxPixels: Int) -> GiovDecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return GiovDecodedImage(image)
    }

    /// The blurred placeholder a message carries, or nil.
    static func placeholder(_ preview: GiovAttachmentPreview?) -> GiovDecodedImage? {
        guard let data = preview?.thumbData else { return nil }
        return decode(data, maxPixels: 64)
    }

    /// The GiovBot mark shipped with the SDK.
    static let botMark: GiovDecodedImage? = {
        guard let url = Bundle.module.url(forResource: "giovbot_mark", withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return decode(data, maxPixels: 256)
    }()
}

/// Re-encodes an image the server does not accept (HEIC, TIFF, ...) as JPEG; nil when it cannot be decoded.
func giovTranscodeToJPEG(_ data: Data, quality: Double = 0.85) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        // Large enough for any photo; the upload limit is checked afterwards.
        kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let image = giovOpaqueImage(decoded)
    else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

/// A photo from the library as a file the chat can send: kept as is when the server accepts its type, else
/// re-encoded as JPEG; with its size and blurred placeholder. Nil when the data is not an image.
func giovPreparePhoto(_ data: Data, index: Int) -> GiovPickedFile? {
    var bytes = data
    var type = giovSniffImageType(data)
    if type == nil {
        guard let jpeg = giovTranscodeToJPEG(data) else { return nil }
        bytes = jpeg
        type = "image/jpeg"
    }
    let mimeType = type ?? "image/jpeg"
    return GiovPickedFile.image(name: giovPhotoFileName(index: index, mimeType: mimeType), mimeType: mimeType, data: bytes)
}

/// Downloads and decodes avatars and image attachments, keeping recent pictures in memory.
actor GiovImageLoader {
    static let shared = GiovImageLoader()

    private let cache = NSCache<NSString, GiovDecodedImage>()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    /// The picture at `url` (http(s) only), at most `maxPixels` on its long side, or nil. `cacheKey` is stable for
    /// the same picture while `url` may carry a credential that changes.
    func load(url: String, cacheKey: String, maxPixels: Int) async -> GiovDecodedImage? {
        let key = "\(cacheKey)@\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard giovIsHTTPURL(url), let target = URL(string: url) else { return nil }
        do {
            let (data, response) = try await session.data(from: target)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let image = GiovDecodedImage.decode(data, maxPixels: maxPixels) else { return nil }
            cache.setObject(image, forKey: key, cost: image.cgImage.bytesPerRow * image.cgImage.height)
            return image
        } catch {
            return nil
        }
    }
}
#endif
