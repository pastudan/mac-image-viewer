import CoreGraphics

/// Pinch zoom inside one pane. Content drawn at `scale`, shifted by `offset`, where
/// `offset` is a fraction of the pane size so it survives window resizes:
/// a point `p` of the fitted content lands at `p * scale + offset * paneSize`.
/// The content always covers the pane once zoomed in, so you can't pan into empty space.
public struct ZoomTransform: Codable, Equatable, Sendable {
    public var scale: CGFloat
    public var offset: CGPoint

    public static let identity = ZoomTransform()
    public static let maxScale: CGFloat = 20

    public init(scale: CGFloat = 1, offset: CGPoint = .zero) {
        self.scale = scale
        self.offset = offset
    }

    public var isZoomed: Bool { scale > 1.001 }

    /// Zooms by `factor`, keeping the content under `point` (pane-local points) fixed.
    public func zoomed(by factor: CGFloat, at point: CGPoint, in size: CGSize) -> ZoomTransform {
        guard size.width > 0, size.height > 0, factor.isFinite, factor > 0 else { return self }
        let newScale = min(max(scale * factor, 1), Self.maxScale)
        let f = newScale / scale
        let q = CGPoint(x: point.x / size.width, y: point.y / size.height)
        let offset = CGPoint(x: q.x - f * (q.x - self.offset.x),
                             y: q.y - f * (q.y - self.offset.y))
        return ZoomTransform(scale: newScale, offset: offset).clamped()
    }

    /// Pans by `delta` points.
    public func panned(by delta: CGSize, in size: CGSize) -> ZoomTransform {
        guard size.width > 0, size.height > 0 else { return self }
        return ZoomTransform(scale: scale,
                             offset: CGPoint(x: offset.x + delta.width / size.width,
                                             y: offset.y + delta.height / size.height)).clamped()
    }

    /// The content's rect within a pane of `size`.
    public func contentRect(in size: CGSize) -> CGRect {
        CGRect(x: offset.x * size.width, y: offset.y * size.height,
               width: size.width * scale, height: size.height * scale)
    }

    func clamped() -> ZoomTransform {
        guard isZoomed else { return .identity }
        let low = 1 - scale
        return ZoomTransform(scale: scale,
                             offset: CGPoint(x: min(max(offset.x, low), 0),
                                             y: min(max(offset.y, low), 0)))
    }
}

/// The hover buttons drawn on a pane. Shared by drawing and hit testing so they can't drift apart.
public enum TileControl: String, Hashable, Sendable {
    case close, playPause, mute
}

public enum TileChrome {
    /// Button rects in the same coordinate space as `pane`. Tiny panes get no buttons.
    public static func rects(in pane: CGRect, hasVideo: Bool) -> [TileControl: CGRect] {
        guard pane.width >= 90, pane.height >= 70 else { return [:] }
        var rects: [TileControl: CGRect] = [
            .close: CGRect(x: pane.minX + 6, y: pane.minY + 4, width: 20, height: 20),
        ]
        if hasVideo, let bar = VideoBarLayout(pane: pane) {
            rects[.playPause] = bar.playPause
            rects[.mute] = bar.mute
        }
        return rects
    }
}

/// The video control bar along the bottom of a pane: play/pause, mute, current time,
/// seek track, total runtime. Used for drawing and hit testing, so they can't drift apart.
/// Small panes get just the track; tiny panes get nothing.
public struct VideoBarLayout: Equatable, Sendable {
    public static let height: CGFloat = 40

    /// The darkened strip behind the controls.
    public let strip: CGRect
    public let playPause: CGRect?
    public let mute: CGRect?
    public let currentLabel: CGRect?
    public let durationLabel: CGRect?
    /// The visible seek line.
    public let track: CGRect
    /// The clickable area around the seek line, taller so it's easy to hit.
    public let trackHitArea: CGRect

    public init?(pane: CGRect) {
        guard pane.width >= 40, pane.height >= 30 else { return nil }
        let rowMid = pane.maxY - 16
        let stripHeight = min(Self.height, pane.height)
        strip = CGRect(x: pane.minX, y: pane.maxY - stripHeight, width: pane.width, height: stripHeight)

        var left = pane.minX + 8
        let right = pane.maxX - 10
        if pane.width >= 90, pane.height >= 70 {
            playPause = CGRect(x: pane.minX + 6, y: rowMid - 12, width: 24, height: 24)
            mute = CGRect(x: pane.minX + 34, y: rowMid - 12, width: 24, height: 24)
            left = pane.minX + 66
        } else {
            playPause = nil
            mute = nil
        }

        var trackLeft = left, trackRight = right
        if right - left >= 128 {
            currentLabel = CGRect(x: left, y: rowMid - 8, width: 40, height: 16)
            durationLabel = CGRect(x: right - 40, y: rowMid - 8, width: 40, height: 16)
            trackLeft = left + 46
            trackRight = right - 46
        } else {
            currentLabel = nil
            durationLabel = nil
        }
        guard trackRight - trackLeft >= 16 else { return nil }
        track = CGRect(x: trackLeft, y: rowMid - 2, width: trackRight - trackLeft, height: 4)
        trackHitArea = track.insetBy(dx: -6, dy: -10)
    }

    /// Position along the track (0...1) for a pointer at `x`.
    public func fraction(atX x: CGFloat) -> Double {
        Double(min(max((x - track.minX) / track.width, 0), 1))
    }
}
