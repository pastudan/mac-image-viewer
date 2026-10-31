import AppKit
import CanvasCore
import ImageIO
import UniformTypeIdentifiers

struct Tile: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
    /// Width / height of the decoded image.
    let aspect: CGFloat

    /// Normalized (0...1) frame within the canvas, top-left origin.
    var frame: CGRect
    /// Set while the tile is snapped to a half, quadrant or the full canvas.
    var zone: SnapZone?
    /// Normalized size to return to when a snapped tile is dragged away.
    var restoreSize: CGSize?
    /// Frame/zone to return to when toggling out of full-canvas via double-click.
    var preFill: (frame: CGRect, zone: SnapZone?)?

    var name: String { url.lastPathComponent }
}

enum ImageLoader {
    /// Longest edge we decode to. Keeps 50MP photos from eating gigabytes.
    static let maxPixelSize = 3000

    static func isImage(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    /// Decodes a downsampled, orientation-corrected image. Safe to call off the main thread.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
