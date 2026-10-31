import CanvasCore
import SwiftUI

struct TileView: View {
    let model: CanvasModel
    let tile: Tile
    let canvasSize: CGSize

    /// Frame (points) at the start of the current move/resize gesture.
    @State private var dragOrigin: CGRect?
    @State private var resizeOrigin: CGRect?
    @State private var hovering = false

    private var rect: CGRect { tile.frame.denormalized(in: canvasSize) }
    private var isSelected: Bool { model.selectedID == tile.id }
    private var isInteracting: Bool { dragOrigin != nil || resizeOrigin != nil }

    var body: some View {
        let r = rect
        // Snapped tiles get a small gutter so neighbours read as separate images.
        let inset: CGFloat = tile.zone == nil ? 0 : 3

        ZStack(alignment: .topLeading) {
            Image(nsImage: tile.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tile.zone == nil ? Color.clear : Color.black.opacity(0.35))

            if hovering && !isInteracting {
                TitleBar(name: tile.name) { model.remove(tile.id) }
                    .transition(.opacity)
            }

            if tile.zone != .full {
                ResizeHandle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .opacity(hovering || resizeOrigin != nil ? 1 : 0)
                    .gesture(resizeGesture)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.08),
                              lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(isInteracting ? 0.5 : 0.3), radius: isInteracting ? 14 : 6, y: 2)
        .padding(inset)
        .frame(width: max(r.width, 1), height: max(r.height, 1))
        .offset(x: r.minX, y: r.minY)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(count: 2) {
            withAnimation(.spring(duration: 0.25)) { model.toggleFill(tile.id) }
        }
        .simultaneousGesture(TapGesture().onEnded { model.bringToFront(tile.id) })
        .gesture(moveGesture)
        .contextMenu {
            Button("Fill Canvas") { withAnimation(.spring(duration: 0.25)) { model.toggleFill(tile.id) } }
            Menu("Snap To") {
                ForEach(SnapZone.allCases, id: \.self) { zone in
                    Button(zone.title) {
                        model.bringToFront(tile.id)
                        withAnimation(.spring(duration: 0.25)) { model.snap(tile.id, to: zone) }
                    }
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tile.url]) }
            Button("Remove from Canvas") { model.remove(tile.id) }
        }
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if dragOrigin == nil {
                    model.bringToFront(tile.id)
                    // Pulling a snapped tile away restores its old size under the pointer.
                    dragOrigin = model.unsnap(tile.id, grabbing: value.startLocation) ?? rect
                }
                guard let origin = dragOrigin else { return }
                let moved = origin.offsetBy(dx: value.translation.width, dy: value.translation.height)
                model.setFrame(tile.id, to: moved)
                let zone = SnapZone.zone(for: value.location, in: canvasSize)
                if zone != model.snapPreview { model.snapPreview = zone }
            }
            .onEnded { value in
                defer {
                    dragOrigin = nil
                    model.snapPreview = nil
                }
                if let zone = SnapZone.zone(for: value.location, in: canvasSize) {
                    withAnimation(.spring(duration: 0.25)) { model.snap(tile.id, to: zone) }
                } else if let current = model.tile(tile.id)?.frame.denormalized(in: canvasSize) {
                    let clamped = model.clampedOnScreen(current, in: canvasSize)
                    if clamped != current {
                        withAnimation(.spring(duration: 0.25)) { model.setFrame(tile.id, to: clamped) }
                    }
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if resizeOrigin == nil {
                    model.bringToFront(tile.id)
                    resizeOrigin = rect
                }
                guard let origin = resizeOrigin, origin.height > 0 else { return }
                // Keep the tile's proportions; drive size by whichever axis moved more.
                let aspect = origin.width / origin.height
                let dw = value.translation.width
                let dh = value.translation.height * aspect
                let width = max(120, origin.width + (abs(dw) > abs(dh) ? dw : dh))
                model.setFrame(tile.id, to: CGRect(x: origin.minX, y: origin.minY,
                                                   width: width, height: width / aspect))
            }
            .onEnded { _ in resizeOrigin = nil }
    }
}

private struct TitleBar: View {
    let name: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Remove from canvas")
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct ResizeHandle: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.black.opacity(0.55)))
            .padding(6)
            .contentShape(Rectangle())
    }
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
        case .full: "Full Canvas"
        }
    }
}
