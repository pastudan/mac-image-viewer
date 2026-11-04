import CanvasCore
import SwiftUI

/// Draws the canvas. Nothing here handles input: every click, drag, pinch and file drop
/// goes to the `InteractionLayer` on top, which hit-tests against the model's geometry.
struct CanvasView: View {
    @Bindable var model: CanvasModel

    /// The "lead" between panes of glass.
    static let lead = Color(nsColor: NSColor(white: 0.07, alpha: 1))

    var body: some View {
        GeometryReader { geo in
            let frames = model.frames()
            ZStack(alignment: .topLeading) {
                Self.lead

                if model.isEmpty {
                    EmptyStateView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                ForEach(model.layout?.ids ?? [], id: \.self) { id in
                    if let tile = model.tiles[id], let slot = frames[id] {
                        TileView(model: model, tile: tile,
                                 pane: slot.insetBy(dx: CanvasModel.gutter, dy: CanvasModel.gutter))
                            .zIndex(zIndex(for: id))
                    }
                }

                if model.draggingID == nil, model.expandedID == nil, let path = model.activeDividerPath,
                   let divider = model.layout?.dividers(in: model.canvasRect).first(where: { $0.path == path }) {
                    DividerHighlight(divider: divider)
                        .zIndex(3)
                }

                if let preview = model.dropPreview {
                    DropPreviewView(rect: preview)
                        .zIndex(5)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
            .overlay(InteractionLayer(model: model))
            .onAppear { model.canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in model.canvasSizeChanged(size) }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func zIndex(for id: UUID) -> Double {
        if model.draggingID == id { return 10 }
        if model.expandedID == id { return 4 }
        return 0
    }
}

/// Highlights the divider under the pointer, or the one being dragged.
private struct DividerHighlight: View {
    let divider: Layout.Divider

    var body: some View {
        let c = divider.container
        let vertical = divider.axis == .columns
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: vertical ? 4 : c.width, height: vertical ? c.height : 4)
            .position(x: vertical ? divider.position : c.midX,
                      y: vertical ? c.midY : divider.position)
    }
}

private struct DropPreviewView: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )
            .frame(width: max(rect.width - 8, 1), height: max(rect.height - 8, 1))
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 44, weight: .light))
            Text("Open images or videos from Finder, or drop them here")
                .font(.title3)
            Text("Everything you open shares the window like panes of stained glass.\nDrag a pane onto another to split it, or to an edge or corner to snap it.")
                .font(.callout)
                .multilineTextAlignment(.center)
            Text("Shift-Command-R restores your last view (Touch ID required).")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .foregroundStyle(.secondary)
    }
}
