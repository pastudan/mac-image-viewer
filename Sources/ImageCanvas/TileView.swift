import AVFoundation
import CanvasCore
import SwiftUI

/// One pane of glass: an image or looping video filling its slot in the layout.
struct TileView: View {
    let model: CanvasModel
    let tile: Tile
    let rect: CGRect

    @State private var hovering = false

    /// Half the width of the lead line between panes.
    private let gutter: CGFloat = 1.5

    private var isSelected: Bool { model.selectedID == tile.id && model.tiles.count > 1 }
    private var isDragging: Bool { model.draggingID == tile.id }

    var body: some View {
        let pane = rect.insetBy(dx: gutter, dy: gutter)

        ZStack {
            Color.black
            content
            if hovering && !isDragging {
                chrome
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        .frame(width: max(pane.width, 1), height: max(pane.height, 1))
        .contentShape(Rectangle())
        // While dragging, the pane shrinks around the grab point and follows the pointer.
        .scaleEffect(isDragging ? ghostScale(pane.size) : 1, anchor: model.dragAnchor)
        .opacity(isDragging ? 0.85 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.6 : 0), radius: 18, y: 6)
        .offset(isDragging ? model.dragTranslation : .zero)
        .position(x: pane.midX, y: pane.midY)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(count: 2) { model.toggleZoom(tile.id) }
        .simultaneousGesture(TapGesture().onEnded { model.selectedID = tile.id })
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(CanvasView.space))
                .onChanged { value in
                    model.dragChanged(tile.id, start: value.startLocation,
                                      location: value.location, translation: value.translation)
                }
                .onEnded { _ in model.dragEnded() }
        )
        .contextMenu { contextMenu }
    }

    /// Shrink big panes while dragging so the drop preview stays visible underneath.
    private func ghostScale(_ size: CGSize) -> CGFloat {
        let target: CGFloat = 260
        return min(1, target / max(size.width, size.height, 1))
    }

    @ViewBuilder
    private var content: some View {
        switch tile.content {
        case .loading:
            ProgressView().controlSize(.small)
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

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.remove(tile.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("Remove from canvas")
                Text(tile.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)

            if let video = tile.video {
                HStack(spacing: 10) {
                    Button { model.togglePlay(tile.id) } label: {
                        Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .help(video.isPlaying ? "Pause" : "Play")
                    Button { model.toggleMute(tile.id) } label: {
                        Image(systemName: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(video.isMuted ? "Unmute" : "Mute")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(model.zoomedID == tile.id ? "Exit Zoom" : "Zoom to Fill Canvas") { model.toggleZoom(tile.id) }
        Menu("Snap To") {
            ForEach(SnapZone.allCases.filter { $0 != .full }, id: \.self) { zone in
                Button(zone.title) { model.snap(tile.id, to: zone) }
            }
        }
        if let video = tile.video {
            Divider()
            Button(video.isPlaying ? "Pause" : "Play") { model.togglePlay(tile.id) }
            Button(video.isMuted ? "Unmute" : "Mute") { model.toggleMute(tile.id) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tile.url]) }
        Button("Remove from Canvas") { model.remove(tile.id) }
    }
}

/// A bare AVPlayerLayer (no system controls) that lets SwiftUI handle all mouse input.
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

    /// Clicks and drags pass through to the SwiftUI gestures on the tile.
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
        case .full: "Fill Canvas"
        }
    }
}
