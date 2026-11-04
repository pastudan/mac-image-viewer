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

    init() {
        let saved = UserDefaults.standard.object(forKey: Self.maxCropKey) as? Double
        maxCrop = CGFloat(saved ?? Double(FitMath.defaultMaxCrop))
    }

    private(set) var tiles: [UUID: Tile] = [:]
    /// Every change to the arrangement is remembered as the "last view" (restorable later
    /// behind Touch ID). Zoom changes call `noteChange` themselves.
    private(set) var layout: Layout? {
        didSet { if layout != oldValue { LastView.shared.noteChange() } }
    }
    var selectedID: UUID?
    /// Pane under the pointer; its hover controls are shown.
    var hoveredID: UUID?
    /// Divider under the pointer or being dragged, by its path in the layout tree.
    var activeDividerPath: [Bool]?
    /// Double-clicked tile shown over the whole canvas; the layout underneath is untouched.
    private(set) var expandedID: UUID?
    /// Crop media to fill each tile instead of letterboxing.
    var cropToFill = false {
        didSet { if cropToFill != oldValue { LastView.shared.noteChange() } }
    }
    /// How much of a picture's edges may be trimmed to close black bars (0...0.25).
    var maxCrop: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(maxCrop), forKey: Self.maxCropKey)
            if layoutIsAuto { refit(animated: true) }
        }
    }
    /// The crop actually used for drawing and scoring.
    var effectiveCrop: CGFloat { cropToFill ? 1 : maxCrop }
    /// True while the layout is the app's own best fit. Dragging, snapping or moving a
    /// divider makes it manual, and then window resizes leave it alone.
    private(set) var layoutIsAuto = true
    private static let maxCropKey = "layout.maxCrop"
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

    /// The control bar layout for a video pane (nil for images and tiny panes).
    func videoBar(for id: UUID) -> VideoBarLayout? {
        guard tiles[id]?.video != nil, let pane = paneRect(id) else { return nil }
        return VideoBarLayout(pane: pane)
    }

    /// The video whose seek track is under `point`, with where along the track (0...1).
    func seekTrack(at point: CGPoint) -> (id: UUID, fraction: Double)? {
        guard let id = tileID(at: point), (tiles[id]?.video?.duration ?? 0) > 0,
              let bar = videoBar(for: id), bar.trackHitArea.contains(point) else { return nil }
        return (id, bar.fraction(atX: point.x))
    }

    func perform(_ control: TileControl, on id: UUID) {
        switch control {
        case .close: remove(id)
        case .playPause: togglePlay(id)
        case .mute: toggleMute(id)
        }
    }

    // MARK: Adding

    /// Adds images and videos as tiles, then re-arranges everything for the least black
    /// space (best fit). New files go last in reading order; a Finder drop puts them at
    /// the drop position in that order instead.
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

        layoutIsAuto = true
        withAnimation(Self.spring) {
            layout = bestLayout(order) ?? Layout.balanced(order, in: canvasSize)
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
                aspectArrived(id, CGFloat(cg.width) / CGFloat(max(cg.height, 1)))
            case .video:
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard playable else { return failed(id, url) }
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                let aspect = await MediaLoader.videoAspect(asset)
                guard tiles[id] != nil else { return } // removed while loading
                let video = LoopingVideo(asset: asset, duration: duration.isFinite ? duration : 0)
                tiles[id]?.content = .video(video)
                AppLock.shared.didLoad(video, id: id)
                aspectArrived(id, aspect ?? 16.0 / 9.0)
            }
        }
    }

    private var refitPending = false

    /// A picture's shape is known now: re-fit, coalescing a burst of loads into one pass.
    private func aspectArrived(_ id: UUID, _ aspect: CGFloat) {
        guard tiles[id] != nil else { return }
        tiles[id]?.aspect = aspect
        guard layoutIsAuto, !refitPending else { return }
        refitPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            refitPending = false
            if layoutIsAuto { refit(animated: true) }
        }
    }

    private func failed(_ id: UUID, _ url: URL) {
        NSLog("Image Canvas: could not open \(url.path)")
        guard tiles[id] != nil else { return }
        remove(id)
        if layoutIsAuto { refit(animated: true) } // close the gap a file that never loaded leaves
    }

    // MARK: Best fit

    /// The arrangement with the least black space for these tiles, in roughly this order.
    func bestLayout(_ order: [UUID]) -> Layout? {
        let items = order.map { (id: $0, aspect: tiles[$0]?.aspect ?? 1) }
        return BestFit.layout(items, in: canvasSize, maxCrop: effectiveCrop)
    }

    /// Re-runs best fit on the current tiles and makes the layout automatic again.
    func refit(animated: Bool) {
        guard let ids = layout?.ids, let best = bestLayout(ids) else { return }
        layoutIsAuto = true
        if best == layout { return }
        if animated {
            withAnimation(Self.spring) { layout = best }
        } else {
            layout = best
        }
    }

    /// The share of the canvas (0...1) left black by the current layout.
    var blackShare: CGFloat {
        guard let layout else { return 0 }
        let aspects = tiles.mapValues { $0.aspect ?? 1 }
        return BestFit.score(layout, aspects: aspects, in: canvasSize, maxCrop: effectiveCrop).black
    }

    /// Window resized: re-fit shortly after it stops changing, unless arranged by hand.
    private var resizeTask: Task<Void, Never>?
    func canvasSizeChanged(_ size: CGSize) {
        guard size != canvasSize else { return }
        canvasSize = size
        guard layoutIsAuto else { return }
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, layoutIsAuto else { return }
            refit(animated: true)
        }
    }

    /// The user arranged something by hand; stop re-fitting automatically.
    func markManual() {
        layoutIsAuto = false
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
        if layoutIsAuto { refit(animated: true) }
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
        layoutIsAuto = true
    }

    // MARK: Arranging

    /// Arrange > Even Out: every tile gets the same share of the canvas (a manual layout).
    func evenOut() {
        guard let ids = layout?.ids else { return }
        markManual()
        withAnimation(Self.spring) { layout = Layout.balanced(ids, in: canvasSize) }
    }

    func snap(_ id: UUID, to zone: SnapZone) {
        if zone == .full { return toggleExpand(id) }
        markManual()
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
        markManual()
        layout = layout?.settingRatio(ratio, at: divider.path)
    }

    // MARK: Pinch zoom (inside a pane)

    func zoom(_ id: UUID, by factor: CGFloat, at point: CGPoint) {
        guard let pane = paneRect(id), let current = tiles[id]?.zoom else { return }
        let local = CGPoint(x: point.x - pane.minX, y: point.y - pane.minY)
        tiles[id]?.zoom = current.zoomed(by: factor, at: local, in: pane.size)
        LastView.shared.noteChange()
    }

    /// Zooms around the centre of the pane (menu and keyboard).
    func zoomSelected(by factor: CGFloat) {
        guard let id = selectedID, let pane = paneRect(id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { zoom(id, by: factor, at: CGPoint(x: pane.midX, y: pane.midY)) }
    }

    func pan(_ id: UUID, by delta: CGSize) {
        guard let pane = paneRect(id), let current = tiles[id]?.zoom, current.isZoomed else { return }
        tiles[id]?.zoom = current.panned(by: delta, in: pane.size)
        LastView.shared.noteChange()
    }

    func resetZoom(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { tiles[id]?.zoom = .identity }
        LastView.shared.noteChange()
    }

    // MARK: Video

    /// Starts a two-finger scrub on a video pane and shows its seek bar.
    @discardableResult
    func beginScrub(_ id: UUID) -> Bool {
        guard !AppLock.shared.isLocked,
              let video = tiles[id]?.video, video.duration > 0, let pane = paneRect(id) else { return false }
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

    /// Mouse seeking on the bar: jumps to a point along the track.
    func scrub(toFraction fraction: Double) {
        guard var s = scrub, let video = tiles[s.id]?.video else { return }
        s.time = min(max(fraction, 0), 1) * s.duration
        scrub = s
        video.seek(to: s.time)
    }

    /// Fingers lifted: hide the seek bar straight away and resume playback.
    func endScrub() {
        guard let s = scrub else { return }
        if !AppLock.shared.isLocked { tiles[s.id]?.video?.endScrub() }
        withAnimation(.easeOut(duration: 0.12)) { scrub = nil }
    }

    func togglePlay(_ id: UUID) {
        guard !AppLock.shared.isLocked else { return } // nothing plays behind the lock screen
        tiles[id]?.video?.togglePlay()
    }

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
                markManual()
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
        markManual() // a saved layout is kept exactly as saved
        selectedID = layout?.ids.first
        for (_, id) in ids.sorted(by: { $0.key < $1.key }) {
            if let tile = tiles[id] { load(id, url: tile.url, kind: tile.kind) }
        }
        return missing
    }
}
