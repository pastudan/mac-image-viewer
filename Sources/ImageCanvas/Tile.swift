import AppKit
import AVFoundation
import CanvasCore
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
    /// Pinch zoom within the pane.
    var zoom: ZoomTransform = .identity
    /// Width / height of the picture as shown (rotation applied). Nil until it loads.
    var aspect: CGFloat?

    var name: String { url.lastPathComponent }

    var isLoaded: Bool {
        if case .loading = content { false } else { true }
    }

    var video: LoopingVideo? {
        if case .video(let v) = content { v } else { nil }
    }
}

/// A muted, endlessly looping video.
@MainActor
@Observable
final class LoopingVideo {
    let player = AVQueuePlayer()
    /// Length of one loop, in seconds (0 if unknown).
    let duration: Double
    private var looper: AVPlayerLooper?
    private(set) var isPlaying = true
    private(set) var isMuted = true

    // Scrubbing: at most one seek in flight, and only the newest target is kept, so a
    // fast swipe never queues up a backlog of stale seeks.
    private var pendingSeek: CMTime?
    private var isSeeking = false

    /// Playback position, published only while someone is watching (the hover bar), so
    /// idle panes don't redraw ten times a second.
    private(set) var position: Double = 0
    private var timeObserver: Any?
    private var watchers = 0

    init(asset: AVAsset, duration: Double) {
        self.duration = duration
        player.isMuted = true
        // Several looping clips shouldn't keep the display awake forever.
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        player.play()
    }

    /// Starts publishing `position`. Balance with `stopWatchingPosition()`.
    func startWatchingPosition() {
        watchers += 1
        position = currentSeconds
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // Each loop is a fresh item, so the clock already restarts at 0 per loop.
                guard let self, time.seconds.isFinite else { return }
                self.position = min(max(time.seconds, 0), self.duration > 0 ? self.duration : time.seconds)
            }
        }
    }

    func stopWatchingPosition() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0, let timeObserver else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    var currentSeconds: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    /// Pauses for scrubbing without changing the play/pause setting.
    func beginScrub() {
        player.pause()
    }

    func seek(to seconds: Double) {
        // Stop just short of the end, so the looper doesn't jump to the next copy.
        let clamped = min(max(seconds, 0), max(duration - 1.0 / 30, 0))
        pendingSeek = CMTime(seconds: clamped, preferredTimescale: 600)
        if !isSeeking { seekToPending() }
    }

    private func seekToPending() {
        guard let target = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isSeeking = false
                    self?.seekToPending()
                }
            }
        }
    }

    /// Resumes playback if it was playing before the scrub.
    func endScrub() {
        if isPlaying { player.play() }
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
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        watchers = 0
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

    /// Width / height of a video as it plays, with its rotation applied (phone videos are tall).
    static func videoAspect(_ asset: AVAsset) async -> CGFloat? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        guard shown.width > 0, shown.height > 0 else { return nil }
        return abs(shown.width) / abs(shown.height)
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
