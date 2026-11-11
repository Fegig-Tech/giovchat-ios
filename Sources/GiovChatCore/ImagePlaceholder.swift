#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO

/// Makes the small image placeholder an upload may carry, so every viewer sees a blurred preview in the right shape
/// before the image loads.
public enum GiovImagePlaceholder {
    /// The placeholder for an encoded image (JPEG, PNG, HEIC, ...).
    public struct Result: Sendable, Equatable {
        /// `data:image/jpeg;base64,...`, at most 6000 characters.
        public let thumbnail: String
        /// The image's displayed size in pixels (after its EXIF orientation).
        public let width: Int
        public let height: Int
    }

    /// Decodes `data`, scales it to about `maxSide` pixels on the long side and encodes it as a JPEG `data:` URI.
    /// Returns nil when the data is not an image or the placeholder cannot be made small enough.
    public static func make(from data: Data, maxSide: Int = 32) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        // Orientations 5 to 8 are rotated by 90 degrees.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let width = rotated ? pixelHeight : pixelWidth
        let height = rotated ? pixelWidth : pixelHeight
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxSide, 1),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let thumbnail = giovOpaqueImage(decoded)
        else { return nil }
        for quality in [0.6, 0.4, 0.25] {
            guard let jpeg = encodeJPEG(thumbnail, quality: quality) else { return nil }
            let uri = "data:image/jpeg;base64," + jpeg.base64EncodedString()
            if uri.utf8.count <= GiovAttachmentLimits.maxThumbnailLength {
                return Result(thumbnail: uri, width: min(width, 20000), height: min(height, 20000))
            }
        }
        return nil
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// `image` drawn over white without an alpha channel. JPEG has no transparency: encoding a transparent PNG as is
/// turns its clear pixels black (the web widget fills white too). Opaque images come back unchanged.
package func giovOpaqueImage(_ image: CGImage) -> CGImage? {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return image
    default: break
    }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)
    return context.makeImage()
}

extension GiovPickedFile {
    /// An image file with its size and placeholder filled in from `data` (see ``GiovImagePlaceholder``).
    public static func image(name: String, mimeType: String, data: Data) -> GiovPickedFile {
        let placeholder = GiovImagePlaceholder.make(from: data)
        return GiovPickedFile(
            name: name,
            mimeType: mimeType,
            data: data,
            width: placeholder?.width,
            height: placeholder?.height,
            thumbnail: placeholder?.thumbnail
        )
    }
}
#endif
