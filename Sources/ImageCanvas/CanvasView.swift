import CanvasCore
import SwiftUI
import UniformTypeIdentifiers

struct CanvasView: View {
    @Bindable var model: CanvasModel

    static let space = "canvas"
    /// The "lead" between panes of glass.
    static let lead = Color(nsColor: NSColor(white: 0.07, alpha: 1))

    var body: some View {
        GeometryReader { geo in
            let frames = model.frames()
            ZStack(alignment: .topLeading) {
                Self.lead
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedID = nil }

                if model.isEmpty {
                    EmptyStateView()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                ForEach(model.layout?.ids ?? [], id: \.self) { id in
                    if let tile = model.tiles[id], let rect = frames[id] {
                        TileView(model: model, tile: tile, rect: rect)
                            .zIndex(zIndex(for: id))
                    }
                }

                if let preview = model.dropPreview {
                    DropPreviewView(rect: preview)
                        .zIndex(5)
                }

                if model.zoomedID == nil, model.draggingID == nil, let layout = model.layout {
                    ForEach(layout.dividers(in: model.canvasRect), id: \.path) { divider in
                        DividerHandle(model: model, divider: divider)
                    }
                    .zIndex(3)
                }
            }
            .coordinateSpace(name: Self.space)
            .clipped()
            .onAppear { model.canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in model.canvasSize = size }
            .onDrop(of: [.fileURL], delegate: FinderDropDelegate(model: model))
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func zIndex(for id: UUID) -> Double {
        if model.draggingID == id { return 10 }
        if model.zoomedID == id { return 4 }
        return 0
    }
}

/// Draggable line between two panes; dragging it resizes both sides.
private struct DividerHandle: View {
    let model: CanvasModel
    let divider: Layout.Divider
    @State private var hovering = false
    @State private var dragging = false

    private let thickness: CGFloat = 10

    var body: some View {
        let c = divider.container
        let vertical = divider.axis == .columns
        let rect = vertical
            ? CGRect(x: divider.position - thickness / 2, y: c.minY, width: thickness, height: c.height)
            : CGRect(x: c.minX, y: divider.position - thickness / 2, width: c.width, height: thickness)

        Rectangle()
            .fill(Color.accentColor.opacity(hovering || dragging ? 0.7 : 0))
            .frame(width: vertical ? 3 : rect.width, height: vertical ? rect.height : 3)
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .onHover { inside in
                hovering = inside
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasView.space))
                    .onChanged { value in
                        dragging = true
                        model.setRatio(of: divider, to: value.location)
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
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
            .allowsHitTesting(false)
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
        }
        .foregroundStyle(.secondary)
    }
}

/// Files dragged in from Finder: shows where they'll land, then adds them there.
private struct FinderDropDelegate: DropDelegate {
    let model: CanvasModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        model.externalDragMoved(to: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.externalDragMoved(to: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        model.externalDragEnded()
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = model.externalDragEnded()
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            model.add(urls: urls, target: target)
        }
        return true
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
