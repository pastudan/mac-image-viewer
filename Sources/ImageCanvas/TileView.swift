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
    private var showsChrome: Bool { model.hoveredID == tile.id && model.draggingID == nil }

    var body: some View {
        let size = CGSize(width: max(pane.width, 1), height: max(pane.height, 1))

        ZStack(alignment: .topLeading) {
            Color.black
            zoomedContent(in: size)
            if showsChrome {
                Chrome(tile: tile, size: size, zoom: tile.zoom)
                    .transition(.opacity)
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
    }

    /// Shrink big panes while dragging so the drop preview stays visible underneath.
    private func ghostScale(_ size: CGSize) -> CGFloat {
        min(1, 260 / max(size.width, size.height, 1))
    }

    /// The media, pinch-zoomed: drawn at `scale` times the pane size and shifted by the offset.
    private func zoomedContent(in size: CGSize) -> some View {
        let r = tile.zoom.contentRect(in: size)
        return media
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }

    @ViewBuilder
    private var media: some View {
        switch tile.content {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: model.cropToFill ? .fill : .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        case .video(let video):
            PlayerLayerView(player: video.player, fill: model.cropToFill)
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
            if let video = tile.video, let play = rects[.playPause], let mute = rects[.mute] {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(width: size.width, height: 40)
                    .offset(y: size.height - 40)
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: play.width, height: play.height)
                    .position(x: play.midX, y: play.midY)
                Image(systemName: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: mute.width, height: mute.height)
                    .position(x: mute.midX, y: mute.midY)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// A bare AVPlayerLayer (no system controls). Never takes mouse input.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
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
        playerLayer.videoGravity = .resizeAspect
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
