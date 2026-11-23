import AppKit
import ImageIO

/// Decodes pictures that arrive from the phone (contact photos, app icons) once, at a bounded size, and keeps them.
///
/// Two reasons: a SwiftUI list re-evaluates its rows constantly, and decoding a JPEG on every pass made contact lists
/// sluggish; and a picture comes from another device, so its size and pixel count are checked before anything is
/// decoded (a tiny file can still claim to be a huge image).
enum ImageCache {
    private static let cache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.countLimit = 600
        return c
    }()

    static let maxBytes = 400_000
    static let maxSide = 4096

    /// A decoded picture, no larger than `maxPixel` on its long side, or nil when the data isn't a sane image.
    static func image(from data: Data, maxPixel: Int = 640) -> NSImage? {
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(maxPixel)
        let key = NSNumber(value: hasher.finalize())
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = decode(data, maxPixel: maxPixel) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    static func decode(_ data: Data, maxPixel: Int) -> NSImage? {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxSide, h <= maxSide else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
