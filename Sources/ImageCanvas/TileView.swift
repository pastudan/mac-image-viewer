import AVFoundation
import CanvasCore
import SwiftUI

/// One pane of glass: an image or looping video in its slot. Display only; input is
/// handled by `InteractionNSView`, which uses the same `TileChrome` rects for the buttons.
struct TileView: View {
    let model: CanvasModel
    let tile: Tile
    /// The visible pane, in canvas coordinates.
    let pane: CGRect

    private var isSelected: Bool { model.selectedID == tile.id && model.tiles.count > 1 }
    private var isDragging: Bool { model.draggingID == tile.id }
    private var scrub: CanvasModel.Scrub? { model.scrub?.id == tile.id ? model.scrub : nil }
    private var isHovered: Bool { model.hoveredID == tile.id && model.draggingID == nil }
    private var showsChrome: Bool { isHovered && scrub == nil }
    /// The full video bar: while hovering, and while scrubbing (trackpad or mouse).
    private var showsVideoBar: Bool { isHovered || scrub != nil }

    var body: some View {
        let size = CGSize(width: max(pane.width, 1), height: max(pane.height, 1))

        ZStack(alignment: .topLeading) {
            Color.black
            zoomedContent(in: size)
            if showsChrome {
                Chrome(tile: tile, size: size, zoom: tile.zoom)
                    .transition(.opacity)
            }
            if let video = tile.video, video.duration > 0 {
                if showsVideoBar {
                    VideoBar(video: video, scrubTime: scrub?.time, size: size)
                        .transition(.opacity)
                } else {
                    RuntimeBadge(duration: video.duration)
                        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        // While dragging, the pane shrinks around the grab point and follows the pointer.
        .scaleEffect(isDragging ? ghostScale(size) : 1, anchor: model.dragAnchor)
        .opacity(isDragging ? 0.85 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.6 : 0), radius: 18, y: 6)
        .offset(isDragging ? model.dragTranslation : .zero)
        .position(x: pane.midX, y: pane.midY)
        .animation(.easeOut(duration: 0.12), value: showsChrome)
        .animation(.easeOut(duration: 0.12), value: showsVideoBar)
    }

    /// Shrink big panes while dragging so the drop preview stays visible underneath.
    private func ghostScale(_ size: CGSize) -> CGFloat {
        min(1, 260 / max(size.width, size.height, 1))
    }

    /// The media, pinch-zoomed: drawn at `scale` times the pane size and shifted by the offset.
    private func zoomedContent(in size: CGSize) -> some View {
        let r = tile.zoom.contentRect(in: size)
        return media(in: r.size)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }

    /// The picture at its smart-crop size: fitted, then enlarged until up to the allowed
    /// share of its edges is trimmed, centred in `box` (the pane, or the zoomed pane).
    @ViewBuilder
    private func media(in box: CGSize) -> some View {
        let shown = tile.aspect.map { FitMath.displaySize(contentAspect: $0, in: box, maxCrop: model.effectiveCrop) } ?? box
        switch tile.content {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: shown.width, height: shown.height)
                .frame(width: box.width, height: box.height)
                .clipped()
        case .video(let video):
            PlayerLayerView(player: video.player)
                .frame(width: shown.width, height: shown.height)
                .frame(width: box.width, height: box.height)
                .clipped()
        }
    }
}

/// Hover controls, placed with the shared `TileChrome` rects (pane-local here).
private struct Chrome: View {
    let tile: Tile
    let size: CGSize
    let zoom: ZoomTransform

    var body: some View {
        let local = CGRect(origin: .zero, size: size)
        let rects = TileChrome.rects(in: local, hasVideo: tile.video != nil)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: min(34, size.height))
            if let close = rects[.close] {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: close.width, height: close.height)
                    .position(x: close.midX, y: close.midY)
                Text(tile.name + (zoom.isZoomed ? String(format: "  ·  %.1f×", zoom.scale) : ""))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: max(size.width - close.maxX - 12, 0), alignment: .leading)
                    .offset(x: close.maxX + 6, y: close.minY + 3)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The runtime, always shown in the corner of a video pane.
private struct RuntimeBadge: View {
    let duration: Double

    var body: some View {
        Text(ScrubMath.timecode(duration))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.6)))
            .padding(6)
    }
}

/// Bottom control bar of a video pane: play/pause, mute, current time, seek track and
/// runtime. Shown on hover and while scrubbing. Placed with the shared `VideoBarLayout`,
/// which `InteractionNSView` also uses for clicks.
private struct VideoBar: View {
    let video: LoopingVideo
    /// Set while scrubbing; otherwise the live playback position is shown.
    let scrubTime: Double?
    let size: CGSize

    var body: some View {
        Group {
            if let bar = VideoBarLayout(pane: CGRect(origin: .zero, size: size)) {
                content(bar)
            }
        }
        .onAppear { video.startWatchingPosition() }
        .onDisappear { video.stopWatchingPosition() }
    }

    private func content(_ bar: VideoBarLayout) -> some View {
        let time = scrubTime ?? video.position
        let progress = video.duration > 0 ? min(max(time / video.duration, 0), 1) : 0
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(width: bar.strip.width, height: bar.strip.height)
                .offset(x: bar.strip.minX, y: bar.strip.minY)
            if let play = bar.playPause {
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: play.width, height: play.height)
                    .position(x: play.midX, y: play.midY)
            }
            if let mute = bar.mute {
                Image(systemName: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: mute.width, height: mute.height)
                    .position(x: mute.midX, y: mute.midY)
            }
            if let current = bar.currentLabel, let total = bar.durationLabel {
                Text(ScrubMath.timecode(time))
                    .frame(width: current.width, height: current.height, alignment: .leading)
                    .position(x: current.midX, y: current.midY)
                Text(ScrubMath.timecode(video.duration))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: total.width, height: total.height, alignment: .trailing)
                    .position(x: total.midX, y: total.midY)
            }
            Capsule().fill(.white.opacity(0.3))
                .frame(width: bar.track.width, height: bar.track.height)
                .offset(x: bar.track.minX, y: bar.track.minY)
            Capsule().fill(.white)
                .frame(width: max(bar.track.width * progress, bar.track.height), height: bar.track.height)
                .offset(x: bar.track.minX, y: bar.track.minY)
            Circle().fill(.white)
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .position(x: bar.track.minX + bar.track.width * progress, y: bar.track.midY)
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// A bare AVPlayerLayer (no system controls). Never takes mouse input. It's sized to the
/// video's own shape by the caller, so filling the layer never distorts or letterboxes.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleNSView(_ view: PlayerNSView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerNSView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension SnapZone {
    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .full: "Fill Window"
        }
    }
}
