import CanvasCore
import SwiftUI

struct CanvasView: View {
    @Bindable var model: CanvasModel
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .init(white: 0.11, alpha: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedID = nil }

                if model.tiles.isEmpty {
                    EmptyStateView()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                if let zone = model.snapPreview {
                    SnapPreviewView(rect: zone.rect.denormalized(in: geo.size))
                }

                ForEach(model.tiles) { tile in
                    TileView(model: model, tile: tile, canvasSize: geo.size)
                }

                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: CanvasView.space)
            .clipped()
            .onAppear { model.canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in model.canvasSize = size }
            .dropDestination(for: URL.self) { urls, location in
                model.add(urls: urls, at: location)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    static let space = "canvas"
}

private struct SnapPreviewView: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
            )
            .padding(6)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: rect)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
            Text("Open images from Finder, or drop them here")
                .font(.title3)
            Text("Drag an image to an edge for a half, or a corner for a quarter.\nDouble-click an image to fill the canvas.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}
