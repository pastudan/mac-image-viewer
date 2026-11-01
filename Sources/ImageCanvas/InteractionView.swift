import AppKit
import CanvasCore
import SwiftUI

/// The one view that receives mouse, trackpad and drag-and-drop input for the canvas.
/// The SwiftUI panes underneath only draw. All hit testing goes through
/// `CanvasModel.tileID(at:)`, `divider(near:)` and `control(at:)`, so whatever is drawn
/// under the pointer is what gets clicked.
struct InteractionLayer: NSViewRepresentable {
    let model: CanvasModel

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        view.model = model
        InteractionNSView.current = view
        return view
    }

    func updateNSView(_ view: InteractionNSView, context: Context) {
        view.model = model
    }
}

final class InteractionNSView: NSView {
    /// The live instance, for the debug self-test.
    static weak var current: InteractionNSView?

    var model: CanvasModel!

    private enum Gesture {
        case none
        /// Mouse is down on a pane; turns into a move once it travels a few points.
        case press(UUID, start: CGPoint)
        case move(UUID, start: CGPoint)
        /// Option-drag on a zoomed pane pans inside it.
        case pan(UUID, last: CGPoint)
        case divider(Layout.Divider)
        case control(UUID, TileControl)
        /// Mouse down on a video's seek track: dragging scrubs.
        case seek(UUID)
    }

    private var gesture: Gesture = .none
    private var pinchTarget: UUID?
    private var tracking: NSTrackingArea?
    private let dragThreshold: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleDown(at: location(event), clickCount: event.clickCount,
                   option: event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) { handleDrag(to: location(event)) }
    override func mouseUp(with event: NSEvent) { handleUp(at: location(event)) }
    override func mouseMoved(with event: NSEvent) { handleHover(at: location(event)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: location(event)) }

    override func mouseExited(with event: NSEvent) {
        guard case .none = gesture else { return }
        model.hoveredID = nil
        model.activeDividerPath = nil
        NSCursor.arrow.set()
    }

    func handleDown(at point: CGPoint, clickCount: Int, option: Bool = false) {
        if let hit = model.control(at: point) {
            gesture = .control(hit.id, hit.control)
            return
        }
        if clickCount == 1, let hit = model.seekTrack(at: point), model.beginScrub(hit.id) {
            model.scrub(toFraction: hit.fraction)
            gesture = .seek(hit.id)
            return
        }
        if let divider = model.divider(near: point) {
            gesture = .divider(divider)
            model.activeDividerPath = divider.path
            updateCursor(at: point)
            return
        }
        guard let id = model.tileID(at: point) else {
            model.selectedID = nil
            gesture = .none
            return
        }
        // Selection is always the pane under the pointer, nothing else.
        model.selectedID = id
        if clickCount == 2 {
            model.toggleExpand(id)
            gesture = .none
            return
        }
        if option, model.tiles[id]?.zoom.isZoomed == true {
            gesture = .pan(id, last: point)
            NSCursor.closedHand.set()
            return
        }
        gesture = .press(id, start: point)
    }

    func handleDrag(to point: CGPoint) {
        switch gesture {
        case let .press(id, start):
            guard hypot(point.x - start.x, point.y - start.y) >= dragThreshold else { return }
            gesture = .move(id, start: start)
            model.hoveredID = nil
            NSCursor.closedHand.set()
            fallthrough
        case .move:
            guard case let .move(id, start) = gesture else { return }
            model.dragChanged(id, start: start, location: point,
                              translation: CGSize(width: point.x - start.x, height: point.y - start.y))
        case let .pan(id, last):
            model.pan(id, by: CGSize(width: point.x - last.x, height: point.y - last.y))
            gesture = .pan(id, last: point)
        case let .divider(divider):
            model.setRatio(of: divider, to: point)
        case let .seek(id):
            if let bar = model.videoBar(for: id) { model.scrub(toFraction: bar.fraction(atX: point.x)) }
        case .control, .none:
            break
        }
    }

    func handleUp(at point: CGPoint) {
        switch gesture {
        case .move:
            model.dragEnded()
        case .seek:
            model.endScrub()
        case let .control(id, control):
            if let hit = model.control(at: point), hit.id == id, hit.control == control {
                model.perform(control, on: id)
            }
        default:
            break
        }
        gesture = .none
        handleHover(at: point)
    }

    func handleHover(at point: CGPoint) {
        guard case .none = gesture else { return }
        let id = model.tileID(at: point)
        if model.hoveredID != id { model.hoveredID = id }
        let path = model.divider(near: point)?.path
        if model.activeDividerPath != path { model.activeDividerPath = path }
        updateCursor(at: point)
    }

    private func updateCursor(at point: CGPoint) {
        switch gesture {
        case let .divider(d):
            (d.axis == .columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        case .move, .pan:
            NSCursor.closedHand.set()
        default:
            if let d = model.divider(near: point) {
                (d.axis == .columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: Trackpad

    override func magnify(with event: NSEvent) {
        handleMagnify(by: 1 + event.magnification, at: location(event), phase: event.phase)
    }

    /// Pinch zooms the pane the pinch started on, around the fingers.
    func handleMagnify(by factor: CGFloat, at point: CGPoint, phase: NSEvent.Phase) {
        if phase.contains(.began) || pinchTarget == nil { pinchTarget = model.tileID(at: point) }
        if let id = pinchTarget {
            model.selectedID = id
            model.zoom(id, by: factor, at: point)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) || phase.isEmpty { pinchTarget = nil }
    }

    /// Two-finger double-tap: zoom in to 2.5x there, or back out.
    override func smartMagnify(with event: NSEvent) {
        let point = location(event)
        guard let id = model.tileID(at: point), let zoom = model.tiles[id]?.zoom else { return }
        model.selectedID = id
        if zoom.isZoomed {
            model.resetZoom(id)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { model.zoom(id, by: 2.5, at: point) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let delta = CGSize(width: event.scrollingDeltaX * (precise ? 1 : 10),
                           height: event.scrollingDeltaY * (precise ? 1 : 10))
        let point = location(event)
        let command = event.modifierFlags.contains(.command)

        // Trackpad gestures carry phases; plain mouse wheels don't.
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            // Scroll deltas follow the content; flip them back to finger direction when
            // natural scrolling is off, so "fingers move right" is the same either way.
            let finger = event.isDirectionInvertedFromDevice ? delta : CGSize(width: -delta.width, height: -delta.height)
            let used = handleTrackpadScroll(phase: event.phase, isMomentum: !event.momentumPhase.isEmpty,
                                            contentDelta: delta, fingerDelta: finger, at: point, command: command)
            if !used { super.scrollWheel(with: event) }
            return
        }
        if !handleScroll(by: delta, at: point, zoomModifier: command) {
            super.scrollWheel(with: event)
        }
    }

    private var scrollGesture = ScrollGesture()
    private var scrollTarget: UUID?
    /// After a scrub, the coasting events macOS sends once the fingers lift are swallowed,
    /// so they can neither keep seeking nor bring the seek bar back.
    private var swallowMomentum = false

    /// Two-finger trackpad scroll:
    /// - sideways on a video: scrub, with a seek bar shown until the fingers lift
    /// - otherwise: pan a zoomed pane (Command: zoom)
    /// Returns false when the scroll wasn't used.
    func handleTrackpadScroll(phase: NSEvent.Phase, isMomentum: Bool, contentDelta: CGSize,
                              fingerDelta: CGSize, at point: CGPoint, command: Bool) -> Bool {
        if isMomentum {
            if swallowMomentum { return true }
            guard let id = scrollTarget, model.tiles[id]?.zoom.isZoomed == true else { return false }
            model.pan(id, by: contentDelta)
            return true
        }
        if phase.contains(.mayBegin) { return true }
        if phase.contains(.began) {
            scrollGesture = ScrollGesture()
            scrollTarget = model.tileID(at: point)
            swallowMomentum = false
        }
        defer {
            if phase.contains(.ended) || phase.contains(.cancelled) {
                if model.scrub != nil {
                    model.endScrub()
                    swallowMomentum = true
                }
                scrollGesture = ScrollGesture()
            }
        }
        if command { return handleScroll(by: contentDelta, at: point, zoomModifier: true) }
        guard let id = scrollTarget, let tile = model.tiles[id] else { return false }

        // A zoomed video pans instead of scrubbing; reset its zoom (Cmd-0) to scrub again.
        let canScrub = (tile.video?.duration ?? 0) > 0 && !tile.zoom.isZoomed
        switch scrollGesture.feed(fingerDelta, canScrub: canScrub) {
        case .undecided:
            return true
        case .scrub:
            if model.scrub?.id != id, !model.beginScrub(id) { return true }
            model.updateScrub(by: fingerDelta.width)
            return true
        case .pan:
            guard tile.zoom.isZoomed else { return false }
            model.pan(id, by: contentDelta)
            return true
        }
    }

    /// Two-finger scroll pans a zoomed pane; Command-scroll zooms (for mouse wheels).
    /// Returns false when the scroll wasn't used.
    @discardableResult
    func handleScroll(by delta: CGSize, at point: CGPoint, zoomModifier: Bool) -> Bool {
        guard let id = model.tileID(at: point), let zoom = model.tiles[id]?.zoom else { return false }
        if zoomModifier {
            model.zoom(id, by: exp(delta.height * 0.01), at: point)
            return true
        }
        guard zoom.isZoomed else { return false }
        model.pan(id, by: delta)
        return true
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = location(event)
        guard let id = model.tileID(at: point), let tile = model.tiles[id] else { return nil }
        model.selectedID = id
        let model = self.model!
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(model.expandedID == id ? "Return to Layout" : "Expand to Fill Window") {
            model.toggleExpand(id)
        })
        if tile.zoom.isZoomed {
            menu.addItem(ClosureMenuItem("Reset Zoom") { model.resetZoom(id) })
        }
        let snap = NSMenuItem(title: "Snap To", action: nil, keyEquivalent: "")
        let snapMenu = NSMenu()
        for zone in SnapZone.allCases where zone != .full {
            snapMenu.addItem(ClosureMenuItem(zone.title) { model.snap(id, to: zone) })
        }
        snap.submenu = snapMenu
        menu.addItem(snap)
        if let video = tile.video {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(video.isPlaying ? "Pause" : "Play") { model.togglePlay(id) })
            menu.addItem(ClosureMenuItem(video.isMuted ? "Unmute" : "Mute") { model.toggleMute(id) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([tile.url])
        })
        menu.addItem(ClosureMenuItem("Remove from Canvas") { model.remove(id) })
        return menu
    }

    // MARK: Files dragged in from Finder

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        Self.fileURLs(on: info.draggingPasteboard)
    }

    /// File URLs on a drag pasteboard (from Finder or from the strip).
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// A drop at `point` (view coordinates) of these files: the same path a real drop takes.
    func simulateDrop(of urls: [URL], at point: CGPoint) {
        model.externalDragMoved(to: point)
        let target = model.externalDragEnded()
        model.add(urls: urls, target: target)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { externalDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { externalDrag(sender) }

    private func externalDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        model.externalDragMoved(to: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.externalDragEnded()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = model.externalDragEnded()
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        model.add(urls: urls, target: target)
        return true
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
