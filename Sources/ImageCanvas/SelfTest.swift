import AppKit
import CanvasCore

/// End-to-end check of mouse routing in the running app, started with
/// `ImageCanvas --self-test <report.json> <four image paths…>`.
///
/// Mouse events are real NSEvents sent through `NSWindow.sendEvent`, so AppKit's own hit
/// testing decides which view receives them. Pinch is driven through the same handler
/// `magnify(with:)` uses, because AppKit can't synthesize gesture events.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--self-test"), args.count > flag + 1 else { return }
        let report = URL(fileURLWithPath: args[flag + 1])
        let files = args.dropFirst(flag + 2).map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            var results: [[String: Any]] = []
            do {
                try await run(files: files) { name, passed, detail in
                    results.append(["name": name, "passed": passed, "detail": detail])
                }
            } catch {
                results.append(["name": "harness", "passed": false, "detail": "\(error)"])
            }
            let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: report)
            if args.contains("--hold") {
                // Leave a zoomed, hovered layout on screen for a window-only screenshot.
                let model = CanvasModel.shared
                model.evenOut()
                if let id = model.layout?.ids.first, let pane = model.paneRect(id) {
                    model.zoom(id, by: 3, at: CGPoint(x: pane.midX, y: pane.midY))
                    model.hoveredID = id
                    model.selectedID = id
                }
                // A window behind others stops redrawing, so bring it forward for the capture.
                NSApp.activate()
                InteractionNSView.current?.window?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                let frames = model.layout?.leafFrames(in: model.canvasRect).map {
                    "\(model.tiles[$0.id]?.name ?? "?") \($0.rect) zoom=\(model.tiles[$0.id]?.zoom.scale ?? 0)"
                } ?? []
                try? frames.joined(separator: "\n").write(to: report.appendingPathExtension("frames"),
                                                           atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(6))
            }
            NSApp.terminate(nil)
        }
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func run(files: [URL], record: (String, Bool, String) -> Void) async throws {
        let model = CanvasModel.shared
        model.add(urls: files)

        // Wait for the window, the interaction view and the decoded images.
        for _ in 0..<100 where !(InteractionNSView.current?.window != nil
                                 && model.tiles.count == files.count
                                 && model.tiles.values.allSatisfy(\.isLoaded)) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let view = InteractionNSView.current, let window = view.window else {
            throw Failure(description: "interaction view never appeared")
        }
        try await Task.sleep(for: .milliseconds(400))
        record("setup", model.tiles.count == 4, "tiles=\(model.tiles.count) canvas=\(model.canvasSize)")

        func center(_ id: UUID) -> CGPoint {
            let r = model.frames()[id]!
            return CGPoint(x: r.midX, y: r.midY)
        }
        func send(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: clicks, pressure: 1)!
            window.sendEvent(event)
        }
        func click(_ point: CGPoint, clicks: Int = 1) {
            send(.leftMouseDown, point, clicks: clicks)
            send(.leftMouseUp, point, clicks: clicks)
        }
        func drag(from a: CGPoint, to b: CGPoint, steps: Int = 12) {
            send(.leftMouseDown, a)
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            send(.leftMouseUp, b)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(450)) }

        let ids = model.layout!.ids // left column top/bottom, then right column top/bottom
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        func name(_ id: UUID?) -> String { id.flatMap { model.tiles[$0]?.name } ?? "nil" }

        // 1. The view that AppKit routes clicks to is the interaction layer.
        let hitView = window.contentView?.hitTest(view.convert(center(a), to: window.contentView!.superview))
        record("clicks reach the interaction layer", hitView === view, "hitTest=\(String(describing: hitView.map { type(of: $0) }))")

        // 2. Clicking each pane selects exactly that pane and moves nothing.
        let before = model.layout
        var clickDetail: [String] = []
        var clicksOK = true
        for id in [a, c, b, d, a] {
            click(center(id))
            clickDetail.append("\(name(id))->\(name(model.selectedID))")
            clicksOK = clicksOK && model.selectedID == id
        }
        record("click selects the pane under the pointer", clicksOK && model.layout == before,
               clickDetail.joined(separator: ", ") + (model.layout == before ? "; layout unchanged" : "; LAYOUT CHANGED"))

        // 3. Dragging a pane onto another's centre swaps them; the dragged one is the one that moves.
        let aSlot = model.frames()[a]!, dSlot = model.frames()[d]!
        drag(from: center(a), to: center(d))
        try await settle()
        let swapped = model.frames()[a] == dSlot && model.frames()[d] == aSlot
        record("drag pane onto another pane's centre swaps them", swapped,
               "a now \(model.frames()[a]!), expected \(dSlot)")

        // 4. Dragging a pane to the left window edge gives it the whole left half.
        drag(from: center(b), to: CGPoint(x: 3, y: model.canvasSize.height / 2))
        try await settle()
        let half = CGRect(x: 0, y: 0, width: model.canvasSize.width / 2, height: model.canvasSize.height)
        let bRect = model.frames()[b]!
        record("drag pane to left edge snaps it to the left half",
               abs(bRect.width - half.width) < 1 && abs(bRect.height - half.height) < 1 && bRect.minX < 1,
               "b=\(bRect)")

        // 5. Dragging a divider moves it.
        model.evenOut()
        try await settle()
        let divider = model.layout!.dividers(in: model.canvasRect).first { $0.path.isEmpty }!
        let start = divider.axis == .columns
            ? CGPoint(x: divider.position, y: model.canvasSize.height * 0.3)
            : CGPoint(x: model.canvasSize.width * 0.3, y: divider.position)
        let delta: CGFloat = 150
        let end = divider.axis == .columns ? CGPoint(x: start.x + delta, y: start.y) : CGPoint(x: start.x, y: start.y + delta)
        drag(from: start, to: end)
        try await settle()
        let moved = model.layout!.dividers(in: model.canvasRect).first { $0.path.isEmpty }!
        record("drag divider moves it", abs(moved.position - (divider.position + delta)) < 2,
               "divider \(divider.axis) \(divider.position) -> \(moved.position)")

        // 6. Pinch zoom zooms only the pane under the fingers, around the fingers.
        model.evenOut()
        try await settle()
        let target = model.layout!.ids[1]
        let fingers = center(target)
        view.handleMagnify(by: 1.6, at: fingers, phase: .began)
        view.handleMagnify(by: 1.5, at: fingers, phase: .changed)
        view.handleMagnify(by: 1.0, at: fingers, phase: .ended)
        let others = model.tiles.values.filter { $0.id != target }.allSatisfy { !$0.zoom.isZoomed }
        let z = model.tiles[target]!.zoom
        record("pinch zooms the pane under the fingers", abs(z.scale - 2.4) < 0.01 && others,
               "scale=\(z.scale) offset=\(z.offset) othersUnzoomed=\(others)")

        // 7. Command-scroll zoom through a real scroll event.
        let other = model.layout!.ids[2]
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0) {
            cg.flags = .maskCommand
            cg.location = window.convertPoint(toScreen: view.convert(center(other), to: nil))
            // Flip to CG global coordinates (top-left origin).
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            cg.location.y = screenH - cg.location.y
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        }
        record("command-scroll zooms the pane under the pointer", model.tiles[other]!.zoom.isZoomed,
               "scale=\(model.tiles[other]!.zoom.scale)")

        // 8. Double-click expands the clicked pane, double-click again returns.
        click(center(c), clicks: 1)
        click(center(c), clicks: 2)
        try await settle()
        let expanded = model.expandedID == c
        click(center(c), clicks: 1)
        click(center(c), clicks: 2)
        try await settle()
        record("double-click expands then returns", expanded && model.expandedID == nil,
               "expanded=\(expanded) after=\(String(describing: model.expandedID))")

        // 9. Save and reload a layout file, preserving geometry and zoom.
        let store = LayoutStore.shared
        let saved = store.directory
        store.directory = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-layouts")
        defer { store.directory = saved }
        model.setRatio(of: model.layout!.dividers(in: model.canvasRect)[0], to: CGPoint(x: model.canvasSize.width * 0.35, y: model.canvasSize.height * 0.35))
        let doc = model.makeDocument(name: "Self Test")
        let url = try store.save(doc)
        let framesBefore = model.layout!.leafFrames(in: model.canvasRect).map { ($0.rect, model.tiles[$0.id]!.url.path, model.tiles[$0.id]!.zoom) }
        model.removeAll()
        // Compare by name: the folder listing may resolve /var to /private/var.
        guard let entry = store.entries.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else {
            throw Failure(description: "saved layout not listed; entries=\(store.entries.map(\.url.path))")
        }
        store.open(entry, into: model)
        let framesAfter = model.layout!.leafFrames(in: model.canvasRect).map { ($0.rect, model.tiles[$0.id]!.url.path, model.tiles[$0.id]!.zoom) }
        let same = framesBefore.count == framesAfter.count && zip(framesBefore, framesAfter).allSatisfy {
            $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
        }
        record("save then open layout restores panes, sizes and zoom", same,
               "file=\(url.lastPathComponent) panes=\(framesAfter.count)")
        try? FileManager.default.removeItem(at: store.directory)
    }
}
