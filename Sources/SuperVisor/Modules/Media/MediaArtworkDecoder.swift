import AppKit
import ImageIO

/// Decodes now-playing artwork — bytes another app chose — to a display-sized image.
enum MediaArtworkDecoder {
    /// Longest edge of the decoded image, in pixels. The largest artwork view is 80pt.
    static let maxPixelSize = 512
    /// Images declaring more pixels than this are refused before any pixel is decoded: a small
    /// file can declare a canvas that costs gigabytes to rasterize.
    static let maxSourcePixels = 64_000_000

    /// The artwork scaled to fit `maxPixelSize`, or `nil` when the bytes are not an image or
    /// declare an oversized canvas. Dimensions come from the header; the pixels are decoded
    /// straight to the thumbnail.
    static func image(from data: Data) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            width <= maxSourcePixels / height
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}
