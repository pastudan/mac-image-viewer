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
    /// Pane under the pointer; its hover controls are shown.
    var hoveredID: UUID?
    /// Divider under the pointer or being dragged, by its path in the layout tree.
    var activeDividerPath: [Bool]?
    /// Double-clicked tile shown over the whole canvas; the layout underneath is untouched.
    private(set) var expandedID: UUID?
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

    /// A two-finger scrub in progress. Its seek bar is shown only while this is set.
    struct Scrub: Equatable {
        let id: UUID
        let duration: Double
        let paneWidth: CGFloat
        var time: Double
    }
    private(set) var scrub: Scrub?

    static let spring = Animation.spring(duration: 0.3, bounce: 0.12)
    /// Half the width of the dark "lead" line between panes.
    static let gutter: CGFloat = 1.5
    private static let incomingID = UUID()

    var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }
    var isEmpty: Bool { tiles.isEmpty }
    var selectedVideo: LoopingVideo? { selectedID.flatMap { tiles[$0]?.video } }

    // MARK: Geometry

    /// Tile slots for drawing, with the expanded tile (if any) covering the canvas.
    func frames() -> [UUID: CGRect] {
        var frames = layout?.frames(in: canvasRect) ?? [:]
        if let expandedID { frames[expandedID] = canvasRect }
        return frames
    }

    /// The visible pane for a tile: its slot minus the lead line.
    func paneRect(_ id: UUID) -> CGRect? {
        frames()[id]?.insetBy(dx: Self.gutter, dy: Self.gutter)
    }

    /// The tile under `point`. This is the only place clicks are mapped to tiles.
    func tileID(at point: CGPoint) -> UUID? {
        if let expandedID { return canvasRect.contains(point) ? expandedID : nil }
        return layout?.leaf(at: point, in: canvasRect)
    }

    func divider(near point: CGPoint) -> Layout.Divider? {
        guard expandedID == nil else { return nil }
        return layout?.divider(near: point, in: canvasRect)
    }

    func control(at point: CGPoint) -> (id: UUID, control: TileControl)? {
        guard let id = tileID(at: point), let pane = paneRect(id), let tile = tiles[id] else { return nil }
        let hit = TileChrome.rects(in: pane, hasVideo: tile.video != nil).first { $0.value.contains(point) }
        return hit.map { (id, $0.key) }
    }

    func perform(_ control: TileControl, on id: UUID) {
        switch control {
        case .close: remove(id)
        case .playPause: togglePlay(id)
        case .mute: toggleMute(id)
        }
    }

    // MARK: Adding

    /// Adds images and videos as tiles, then evens out the whole canvas so every pane gets
    /// the same share. New files go last in reading order; a Finder drop puts them at the
    /// drop position in that order instead.
    func add(urls: [URL], target: DropTarget<UUID>? = nil) {
        var added: [(id: UUID, url: URL, kind: MediaKind)] = []
        for url in urls {
            guard let kind = MediaLoader.kind(of: url) else { continue }
            let id = UUID()
            tiles[id] = Tile(id: id, url: url, kind: kind)
            added.append((id, url, kind))
        }
        guard let first = added.first else { return }
        let newIDs = added.map(\.id)

        var order = layout?.ids ?? []
        if let target, let layout {
            // Use the drop target only to decide where the new files sit in the order.
            order = layout.applying(target, moving: first.id, in: canvasSize).ids
            if let at = order.firstIndex(of: first.id) {
                order.insert(contentsOf: newIDs.dropFirst(), at: at + 1)
            }
        } else {
            order += newIDs
        }

        withAnimation(Self.spring) {
            layout = Layout.balanced(order, in: canvasSize)
            expandedID = nil
        }
        selectedID = newIDs.last
        for item in added { load(item.id, url: item.url, kind: item.kind) }
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
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                guard tiles[id] != nil else { return } // removed while loading
                tiles[id]?.content = .video(LoopingVideo(asset: asset, duration: duration.isFinite ? duration : 0))
            }
        }
    }

    private func failed(_ id: UUID, _ url: URL) {
        NSLog("Image Canvas: could not open \(url.path)")
        guard tiles[id] != nil else { return }
        remove(id)
        evenOut() // keep the panes even after a file that never loaded drops out
    }

    // MARK: Removing

    func remove(_ id: UUID) {
        if scrub?.id == id { scrub = nil }
        tiles[id]?.video?.stop()
        tiles[id] = nil
        withAnimation(Self.spring) {
            layout = layout?.removing(id)
            if expandedID == id { expandedID = nil }
        }
        if selectedID == id { selectedID = layout?.ids.last }
        if hoveredID == id { hoveredID = nil }
    }

    func removeSelected() {
        if let selectedID { remove(selectedID) }
    }

    func removeAll() {
        scrub = nil
        for tile in tiles.values { tile.video?.stop() }
        tiles.removeAll()
        layout = nil
        selectedID = nil
        hoveredID = nil
        expandedID = nil
        activeDividerPath = nil
    }

    // MARK: Arranging

    /// Arrange > Even Out: every tile gets the same share of the canvas.
    func evenOut() {
        guard let ids = layout?.ids else { return }
        withAnimation(Self.spring) { layout = Layout.balanced(ids, in: canvasSize) }
    }

    func snap(_ id: UUID, to zone: SnapZone) {
        if zone == .full { return toggleExpand(id) }
        withAnimation(Self.spring) {
            expandedID = nil
            layout = Layout.snapping(id, to: zone, in: layout)
        }
    }

    /// Double-click: show one pane over the whole canvas, or put it back.
    func toggleExpand(_ id: UUID) {
        selectedID = id
        withAnimation(Self.spring) { expandedID = expandedID == id ? nil : id }
    }

    func collapse() {
        withAnimation(Self.spring) { expandedID = nil }
    }

    func setRatio(of divider: Layout.Divider, to point: CGPoint) {
        let c = divider.container
        let ratio = divider.axis == .columns
            ? (point.x - c.minX) / max(c.width, 1)
            : (point.y - c.minY) / max(c.height, 1)
        layout = layout?.settingRatio(ratio, at: divider.path)
    }

    // MARK: Pinch zoom (inside a pane)

    func zoom(_ id: UUID, by factor: CGFloat, at point: CGPoint) {
        guard let pane = paneRect(id), let current = tiles[id]?.zoom else { return }
        let local = CGPoint(x: point.x - pane.minX, y: point.y - pane.minY)
        tiles[id]?.zoom = current.zoomed(by: factor, at: local, in: pane.size)
    }

    /// Zooms around the centre of the pane (menu and keyboard).
    func zoomSelected(by factor: CGFloat) {
        guard let id = selectedID, let pane = paneRect(id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { zoom(id, by: factor, at: CGPoint(x: pane.midX, y: pane.midY)) }
    }

    func pan(_ id: UUID, by delta: CGSize) {
        guard let pane = paneRect(id), let current = tiles[id]?.zoom, current.isZoomed else { return }
        tiles[id]?.zoom = current.panned(by: delta, in: pane.size)
    }

    func resetZoom(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { tiles[id]?.zoom = .identity }
    }

    // MARK: Video

    /// Starts a two-finger scrub on a video pane and shows its seek bar.
    @discardableResult
    func beginScrub(_ id: UUID) -> Bool {
        guard let video = tiles[id]?.video, video.duration > 0, let pane = paneRect(id) else { return false }
        video.beginScrub()
        selectedID = id
        withAnimation(.easeOut(duration: 0.1)) {
            scrub = Scrub(id: id, duration: video.duration, paneWidth: pane.width, time: video.currentSeconds)
        }
        return true
    }

    /// Moves the scrub by a horizontal finger movement (positive = fingers moving right = forward).
    func updateScrub(by fingerDistance: CGFloat) {
        guard var s = scrub, let video = tiles[s.id]?.video else { return }
        s.time = ScrubMath.advance(s.time, by: fingerDistance, paneWidth: s.paneWidth, duration: s.duration)
        scrub = s
        video.seek(to: s.time)
    }

    /// Fingers lifted: hide the seek bar straight away and resume playback.
    func endScrub() {
        guard let s = scrub else { return }
        tiles[s.id]?.video?.endScrub()
        withAnimation(.easeOut(duration: 0.12)) { scrub = nil }
    }

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
        guard expandedID == nil, let layout else { return }
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

    // MARK: Saved layouts

    func makeDocument(name: String) -> LayoutDocument {
        LayoutDocument(name: name, savedAt: Date(), cropToFill: cropToFill, layout: layout) { id in
            tiles[id].map { LayoutDocument.Item(path: $0.url.path, zoom: $0.zoom) }
        }
    }

    /// Replaces the canvas with a saved layout. Returns the paths that no longer exist;
    /// their panes are dropped and their neighbours expand into the space.
    @discardableResult
    func apply(_ document: LayoutDocument) -> [String] {
        removeAll()
        cropToFill = document.cropToFill
        var ids: [Int: UUID] = [:]
        var missing: [String] = []
        for (index, item) in document.items.enumerated() {
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: item.path), let kind = MediaLoader.kind(of: url) else {
                missing.append(item.path)
                continue
            }
            let id = UUID()
            var tile = Tile(id: id, url: url, kind: kind)
            tile.zoom = item.zoom
            tiles[id] = tile
            ids[index] = id
        }
        var restored = document.layout?.compactMapIDs { ids[$0] }
        // Items the saved tree didn't mention still get a pane.
        let placed = Set(restored?.ids ?? [])
        for index in ids.keys.sorted() where !placed.contains(ids[index]!) {
            restored = Layout.adding(ids[index]!, to: restored, in: canvasSize)
        }
        layout = restored
        selectedID = layout?.ids.first
        for (_, id) in ids.sorted(by: { $0.key < $1.key }) {
            if let tile = tiles[id] { load(id, url: tile.url, kind: tile.kind) }
        }
        return missing
    }
}
