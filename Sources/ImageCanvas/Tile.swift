import AppKit
import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers

enum MediaKind {
    case image, video
}

enum TileContent {
    case loading
    case image(NSImage)
    case video(LoopingVideo)
}

struct Tile: Identifiable {
    let id: UUID
    let url: URL
    let kind: MediaKind
    var content: TileContent = .loading

    var name: String { url.lastPathComponent }

    var video: LoopingVideo? {
        if case .video(let v) = content { v } else { nil }
    }
}

/// A muted, endlessly looping video.
@MainActor
@Observable
final class LoopingVideo {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private(set) var isPlaying = true
    private(set) var isMuted = true

    init(asset: AVAsset) {
        player.isMuted = true
        // Several looping clips shouldn't keep the display awake forever.
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        player.play()
    }

    func togglePlay() {
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

enum MediaLoader {
    /// Longest edge images are decoded to. Keeps 50MP photos from eating gigabytes.
    static let maxPixelSize = 3000

    static func kind(of url: URL) -> MediaKind? {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    /// Decodes a downsampled, orientation-corrected image. Safe to call off the main thread.
    static func loadImage(_ url: URL) -> CGImage? {
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
