import AppKit
import AVFoundation
import CanvasCore
import Observation
import SwiftUI

typealias Layout = LayoutNode<UUID>

/// The canvas: a set of media tiles arranged as stained glass. They always fill the
/// window with no gaps; adding or moving one splits a neighbour and the rest shrink.
@MainActor
@Observable
final class CanvasModel {
    static let shared = CanvasModel()

    private(set) var tiles: [UUID: Tile] = [:]
    private(set) var layout: Layout?
    var selectedID: UUID?
    /// Double-clicked tile shown over the whole canvas; the layout underneath is untouched.
    private(set) var zoomedID: UUID?
    /// Crop media to fill each tile instead of letterboxing.
    var cropToFill = false
    /// Current canvas size in points, kept up to date by CanvasView.
    var canvasSize = CGSize(width: 1280, height: 790)

    // Dragging a tile.
    private(set) var draggingID: UUID?
    private(set) var dragTranslation: CGSize = .zero
    /// Grab point within the dragged tile (0...1), so the shrunken ghost stays under the pointer.
    private(set) var dragAnchor: UnitPoint = .center
    private var dropTarget: DropTarget<UUID>?
    private var externalTarget: DropTarget<UUID>?
    /// Where the dragged tile, or files dragged in from Finder, would land.
    private(set) var dropPreview: CGRect?

    static let spring = Animation.spring(duration: 0.3, bounce: 0.12)
    private static let incomingID = UUID()

    var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }
    var isEmpty: Bool { tiles.isEmpty }
    var selectedVideo: LoopingVideo? { selectedID.flatMap { tiles[$0]?.video } }

    /// Tile rects for drawing, with the zoomed tile (if any) covering the canvas.
    func frames() -> [UUID: CGRect] {
        var frames = layout?.frames(in: canvasRect) ?? [:]
        if let zoomedID { frames[zoomedID] = canvasRect }
        return frames
    }

    // MARK: Adding

    /// Adds images and videos as tiles. With no target each one halves the largest tile;
    /// with a target (a Finder drop) the first lands there and the rest stack beside it.
    func add(urls: [URL], target: DropTarget<UUID>? = nil) {
        var previous: UUID?
        for url in urls {
            guard let kind = MediaLoader.kind(of: url) else { continue }
            let id = UUID()
            tiles[id] = Tile(id: id, url: url, kind: kind)
            withAnimation(Self.spring) {
                if let previous, let layout {
                    let rect = layout.frames(in: canvasRect)[previous] ?? .zero
                    self.layout = layout.inserting(id, beside: previous,
                                                   on: rect.width >= rect.height ? .right : .bottom)
                } else if let target, let layout {
                    self.layout = layout.applying(target, moving: id, in: canvasSize)
                } else {
                    self.layout = Layout.adding(id, to: layout, in: canvasSize)
                }
                zoomedID = nil
            }
            if target != nil { previous = id }
            selectedID = id
            load(id, url: url, kind: kind)
        }
    }

    private func load(_ id: UUID, url: URL, kind: MediaKind) {
        Task {
            switch kind {
            case .image:
                let cg = await Task.detached(priority: .userInitiated) { MediaLoader.loadImage(url) }.value
                guard let cg else { return failed(id, url) }
                tiles[id]?.content = .image(NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
            case .video:
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard playable else { return failed(id, url) }
                guard tiles[id] != nil else { return } // removed while loading
                tiles[id]?.content = .video(LoopingVideo(asset: asset))
            }
        }
    }

    private func failed(_ id: UUID, _ url: URL) {
        NSLog("Image Canvas: could not open \(url.path)")
        remove(id)
    }

    // MARK: Removing

    func remove(_ id: UUID) {
        tiles[id]?.video?.stop()
        tiles[id] = nil
        withAnimation(Self.spring) {
            layout = layout?.removing(id)
            if zoomedID == id { zoomedID = nil }
        }
        if selectedID == id { selectedID = layout?.ids.last }
    }

    func removeSelected() {
        if let selectedID { remove(selectedID) }
    }

    func removeAll() {
        for tile in tiles.values { tile.video?.stop() }
        tiles.removeAll()
        layout = nil
        selectedID = nil
        zoomedID = nil
    }

    // MARK: Arranging

    /// Arrange > Even Out: every tile gets the same share of the canvas.
    func evenOut() {
        guard let ids = layout?.ids else { return }
        withAnimation(Self.spring) { layout = Layout.balanced(ids, in: canvasSize) }
    }

    func snap(_ id: UUID, to zone: SnapZone) {
        if zone == .full { return toggleZoom(id) }
        withAnimation(Self.spring) {
            zoomedID = nil
            layout = Layout.snapping(id, to: zone, in: layout)
        }
    }

    func toggleZoom(_ id: UUID) {
        selectedID = id
        withAnimation(Self.spring) { zoomedID = zoomedID == id ? nil : id }
    }

    func exitZoom() {
        withAnimation(Self.spring) { zoomedID = nil }
    }

    func setRatio(of divider: Layout.Divider, to point: CGPoint) {
        let c = divider.container
        let ratio = divider.axis == .columns
            ? (point.x - c.minX) / max(c.width, 1)
            : (point.y - c.minY) / max(c.height, 1)
        layout = layout?.settingRatio(ratio, at: divider.path)
    }

    // MARK: Video

    func togglePlay(_ id: UUID) { tiles[id]?.video?.togglePlay() }

    /// Unmuting one video mutes the rest, so only one soundtrack plays at a time.
    func toggleMute(_ id: UUID) {
        guard let video = tiles[id]?.video else { return }
        let unmute = video.isMuted
        if unmute { for tile in tiles.values where tile.id != id { tile.video?.setMuted(true) } }
        video.setMuted(!unmute)
    }

    // MARK: Dragging tiles

    func dragChanged(_ id: UUID, start: CGPoint, location: CGPoint, translation: CGSize) {
        guard zoomedID == nil, let layout else { return }
        if draggingID == nil {
            draggingID = id
            selectedID = id
            let rect = layout.frames(in: canvasRect)[id] ?? canvasRect
            dragAnchor = UnitPoint(x: (start.x - rect.minX) / max(rect.width, 1),
                                   y: (start.y - rect.minY) / max(rect.height, 1))
        }
        guard draggingID == id else { return }
        dragTranslation = translation
        let target = layout.dropTarget(at: location, in: canvasSize, moving: id)
        if target != dropTarget {
            dropTarget = target
            withAnimation(.easeOut(duration: 0.15)) {
                dropPreview = target.flatMap { layout.applying($0, moving: id, in: canvasSize).frames(in: canvasRect)[id] }
            }
        }
    }

    func dragEnded() {
        guard let id = draggingID else { return }
        withAnimation(Self.spring) {
            if let dropTarget, let layout {
                self.layout = layout.applying(dropTarget, moving: id, in: canvasSize)
            }
            draggingID = nil
            dragTranslation = .zero
            dropTarget = nil
            dropPreview = nil
        }
    }

    // MARK: Dragging files in from Finder

    func externalDragMoved(to point: CGPoint) {
        let target = layout?.dropTarget(at: point, in: canvasSize, moving: nil)
        let preview: CGRect
        if let layout, let target {
            preview = layout.applying(target, moving: Self.incomingID, in: canvasSize)
                .frames(in: canvasRect)[Self.incomingID] ?? canvasRect
        } else {
            preview = canvasRect
        }
        externalTarget = target
        if preview != dropPreview {
            withAnimation(.easeOut(duration: 0.15)) { dropPreview = preview }
        }
    }

    /// Ends a Finder drag and returns where the files should go.
    @discardableResult
    func externalDragEnded() -> DropTarget<UUID>? {
        defer {
            externalTarget = nil
            withAnimation(.easeOut(duration: 0.15)) { dropPreview = nil }
        }
        return externalTarget
    }
}
