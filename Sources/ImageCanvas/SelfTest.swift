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
        // File arguments, skipping flags and the value after --strip-folder.
        var rest: [String] = []
        var skipNext = false
        var inFitList = false
        for arg in args.dropFirst(flag + 2) {
            if skipNext { skipNext = false; continue }
            if arg == "--strip-folder" { skipNext = true; continue }
            if arg.hasPrefix("--") { inFitList = arg == "--fit-images"; continue }
            if !inFitList { rest.append(arg) }
        }
        let files = rest.map { URL(fileURLWithPath: $0) }
        let images = files.filter { MediaLoader.kind(of: $0) == .image }
        let videos = files.filter { MediaLoader.kind(of: $0) == .video }
        // The user's own strip folder may be private; keep it off screen for the whole run.
        MediaStrip.shared.hiddenForCapture = true
        Task { @MainActor in
            var results: [[String: Any]] = []
            let record: (String, Bool, String) -> Void = { name, passed, detail in
                results.append(["name": name, "passed": passed, "detail": detail])
            }
            do {
                if images.count >= 4 {
                    try await run(files: Array(images.prefix(4)), record: record)
                }
                if let video = videos.first {
                    try await runScrub(video: video, record: record)
                    try await runHoverSeek(video: video, record: record)
                    try await runLock(video: video, image: images.first, record: record)
                }
                if let folderArg = args.firstIndex(of: "--strip-folder"), args.count > folderArg + 1 {
                    try await runStrip(folder: URL(fileURLWithPath: args[folderArg + 1]), record: record)
                }
                if let fitArg = args.firstIndex(of: "--fit-images") {
                    let fitFiles = args[(fitArg + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
                    try await runBestFit(files: fitFiles, record: record)
                }
            } catch {
                results.append(["name": "harness", "passed": false, "detail": "\(error)"])
            }
            let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: report)
            if args.contains("--hold") {
                // Leave a zoomed, hovered layout on screen for a window-only screenshot.
                let model = CanvasModel.shared
                // Never show the user's own strip folder in a capture. --hold-strip shows the
                // strip, but only after pointing it at the test folder below.
                MediaStrip.shared.hiddenForCapture = true
                if args.contains("--hold-strip"), let folderArg = args.firstIndex(of: "--strip-folder") {
                    // Strip showing the folder, with a couple of items already on the canvas.
                    // The user's own strip folder setting is put back afterwards.
                    let strip = MediaStrip.shared
                    let defaults = UserDefaults.standard
                    let savedFolder = defaults.string(forKey: "strip.folderPath")
                    strip.setFolder(URL(fileURLWithPath: args[folderArg + 1]))
                    if let savedFolder { defaults.set(savedFolder, forKey: "strip.folderPath") }
                    else { defaults.removeObject(forKey: "strip.folderPath") }
                    await strip.waitForScan()
                    strip.hiddenForCapture = false // now showing only the test folder
                    model.removeAll()
                    model.add(urls: Array((strip.result?.sections.flatMap(\.items) ?? []).prefix(2)).map(\.url))
                    try? await Task.sleep(for: .milliseconds(1500)) // thumbnails
                } else if args.contains("--hold-hover") {
                    // Two videos side by side: the first hovered, the second showing just its runtime.
                    model.removeAll()
                    model.add(urls: Array(videos.prefix(2)))
                    for _ in 0..<50 where !model.tiles.values.allSatisfy({ ($0.video?.duration ?? 0) > 0 }) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(1500)) // let the hovered clip play a little
                }
                let holdFit = args.contains("--hold-fit")
                if holdFit, let fitArg = args.firstIndex(of: "--fit-images") {
                    // The mixed-shape pictures, best fit (or even split with --hold-even).
                    let fitFiles = args[(fitArg + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
                    model.removeAll()
                    model.add(urls: fitFiles)
                    for _ in 0..<60 where !model.tiles.values.allSatisfy({ $0.aspect != nil && $0.isLoaded }) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    if args.contains("--hold-even") { model.evenOut() } else { model.refit(animated: false) }
                } else {
                    model.evenOut()
                }
                if holdFit {
                    // Nothing else; just the arrangement.
                } else if args.contains("--hold-locked") {
                    AppLock.shared.lock()
                } else if let id = model.layout?.ids.first, let pane = model.paneRect(id) {
                    if model.tiles[id]?.video != nil {
                        if args.contains("--hold-hover") {
                            // Hover the first video; any other video shows just its runtime.
                            model.hoveredID = id
                        } else {
                            // Show the seek bar mid-scrub.
                            model.beginScrub(id)
                            model.updateScrub(by: pane.width * 0.4)
                        }
                    } else {
                        model.zoom(id, by: 3, at: CGPoint(x: pane.midX, y: pane.midY))
                        model.hoveredID = id
                    }
                    model.selectedID = id
                }
                // A window behind others stops redrawing, so bring it forward for the capture.
                NSApp.activate()
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                var frames = model.layout?.leafFrames(in: model.canvasRect).map {
                    "\(model.tiles[$0.id]?.name ?? "?") \($0.rect) zoom=\(model.tiles[$0.id]?.zoom.scale ?? 0)"
                } ?? []
                frames.append(String(format: "black=%.1f%% canvas=%.0fx%.0f", model.blackShare * 100,
                                     model.canvasSize.width, model.canvasSize.height))
                try? frames.joined(separator: "\n").write(to: report.appendingPathExtension("frames"),
                                                           atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(6))
            }
            NSApp.terminate(nil)
        }
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    /// Sleep lock. Posts the real workspace sleep notification. Authentication is stubbed
    /// because a test can't touch the sensor; the settings value is restored afterwards.
    private static func runLock(video: URL, image: URL?, record: (String, Bool, String) -> Void) async throws {
        let model = CanvasModel.shared
        let lock = AppLock.shared
        let savedSetting = lock.requireOnWake
        let savedAuth = lock.authenticator
        let savedFront = lock.isFrontmost
        defer {
            lock.requireOnWake = savedSetting
            lock.authenticator = savedAuth
            lock.isFrontmost = savedFront
        }
        model.removeAll()
        model.add(urls: [video] + (image.map { [$0] } ?? []))
        for _ in 0..<100 where !(model.tiles.values.allSatisfy(\.isLoaded) && model.tiles.count >= 1) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let videoID = model.tiles.values.first(where: { $0.video != nil })?.id,
              let player = model.tiles[videoID]?.video else { throw Failure(description: "video never loaded") }
        try await Task.sleep(for: .milliseconds(300))
        let sleep = { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil) }

        // Setting off: sleeping does nothing.
        lock.requireOnWake = false
        sleep()
        try await Task.sleep(for: .milliseconds(200))
        record("sleep with setting off does not lock", !lock.isLocked && player.player.rate > 0,
               "locked=\(lock.isLocked) rate=\(player.player.rate)")

        // Setting on: sleeping locks, hides the canvas and pauses video.
        lock.requireOnWake = true
        var prompts = 0
        lock.authenticator = { _ in prompts += 1; return .cancelled }
        sleep()
        try await Task.sleep(for: .milliseconds(300))
        let interactionGone = InteractionNSView.current?.window == nil
        record("sleep with setting on locks, hides canvas, pauses video",
               lock.isLocked && player.player.rate == 0 && interactionGone,
               "locked=\(lock.isLocked) rate=\(player.player.rate) canvasViewRemoved=\(interactionGone)")

        // Waking with the app in front prompts once; cancelling keeps it locked and
        // reactivation after the cancel does not re-prompt.
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(300))
        let reallyActive = NSApp.isActive
        // In the background: waking must not prompt.
        lock.isFrontmost = { false }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(600))
        let whileBackground = prompts
        // In front: waking prompts once.
        lock.isFrontmost = { true }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(600))
        let afterWake = prompts
        // After a cancel, the app becoming active again doesn't re-prompt.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(600))
        model.togglePlay(videoID)
        let stillPaused = player.player.rate == 0
        record("wake prompts once only when in front; cancel stays locked; nothing plays behind lock",
               whileBackground == 0 && afterWake == 1 && prompts == 1 && lock.isLocked && stillPaused,
               "background=\(whileBackground) afterWake=\(afterWake) total=\(prompts) locked=\(lock.isLocked) paused=\(stillPaused) (test process really frontmost: \(reallyActive))")

        // A failed attempt shows the reason and stays locked.
        lock.authenticator = { _ in .failed("Touch ID didn't match.") }
        await lock.unlock()
        record("failed unlock stays locked with message", lock.isLocked && lock.message == "Touch ID didn't match.",
               "locked=\(lock.isLocked) message=\(lock.message ?? "nil")")

        // Success reveals the canvas and resumes the video.
        lock.authenticator = { _ in .success }
        await lock.unlock()
        try await Task.sleep(for: .milliseconds(400))
        record("successful unlock shows canvas and resumes video",
               !lock.isLocked && player.player.rate > 0 && InteractionNSView.current?.window != nil,
               "locked=\(lock.isLocked) rate=\(player.player.rate)")
    }

    /// Best fit on pictures of mixed shapes: much less black than an even split, every
    /// pane trimmed by no more than the allowance, and a manual edit stops auto re-fitting.
    private static func runBestFit(files: [URL], record: (String, Bool, String) -> Void) async throws {
        let model = CanvasModel.shared
        model.removeAll()
        model.add(urls: files)
        for _ in 0..<100 where !(model.tiles.count == files.count && model.tiles.values.allSatisfy { $0.aspect != nil }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(600))
        guard model.tiles.count == files.count else { throw Failure(description: "fit images never loaded") }
        let shapes = model.layout?.ids.compactMap { id in model.tiles[id].map { String(format: "%@ %.2f", $0.name, $0.aspect ?? 0) } } ?? []

        let fitted = model.layout
        let fittedBlack = model.blackShare
        model.evenOut()
        let evenBlack = model.blackShare
        model.refit(animated: false)
        let refitBlack = model.blackShare
        record("best fit leaves much less black than an even split",
               fittedBlack < evenBlack * 0.5 && fittedBlack < 0.12 && abs(refitBlack - fittedBlack) < 0.001,
               String(format: "bestFit=%.1f%% even=%.1f%% (window %.0fx%.0f) shapes=%@",
                      fittedBlack * 100, evenBlack * 100, model.canvasSize.width, model.canvasSize.height,
                      shapes.joined(separator: ", ")))

        // No picture loses more than the allowed share of its edges.
        var worstTrim: CGFloat = 0
        for (id, rect) in model.frames() {
            guard let aspect = model.tiles[id]?.aspect else { continue }
            let pane = rect.insetBy(dx: CanvasModel.gutter, dy: CanvasModel.gutter).size
            worstTrim = max(worstTrim, FitMath.trimmed(contentAspect: aspect, in: pane, maxCrop: model.effectiveCrop))
        }
        record("no picture is trimmed by more than the allowance", worstTrim <= model.effectiveCrop + 0.001,
               String(format: "worst trim %.1f%% (allowed %.0f%%)", worstTrim * 100, model.effectiveCrop * 100))

        // Adding a picture re-fits automatically.
        if let extra = files.first {
            model.add(urls: [extra])
            for _ in 0..<50 where !model.tiles.values.allSatisfy({ $0.aspect != nil }) {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(300))
            record("adding a picture keeps the layout tight", model.layoutIsAuto && model.blackShare < 0.15,
                   String(format: "tiles=%d black=%.1f%%", model.tiles.count, model.blackShare * 100))
        }

        // A manual edit (moving a divider) turns auto re-fit off: a resize then changes nothing.
        if let divider = model.layout?.dividers(in: model.canvasRect).first {
            let c = divider.container
            model.setRatio(of: divider, to: CGPoint(x: c.minX + c.width * 0.3, y: c.minY + c.height * 0.3))
            let manual = model.layout
            let size = model.canvasSize
            model.canvasSizeChanged(CGSize(width: size.width - 40, height: size.height))
            try await Task.sleep(for: .milliseconds(500))
            let untouched = model.layout == manual
            model.canvasSizeChanged(size)
            // Best Fit (Cmd-G) brings it back.
            model.refit(animated: false)
            record("manual edits stop auto re-fit; Best Fit restores it",
                   !(model.layoutIsAuto && !untouched) && untouched && model.layoutIsAuto && fitted != nil,
                   "layoutKeptAfterResize=\(untouched) autoAfterBestFit=\(model.layoutIsAuto)")
        }
    }

    /// The folder strip: scanning, the strip on screen, and dragging an item onto the canvas.
    /// The drag payload is the exact provider the strip hands to AppKit, written to a real
    /// pasteboard and read back by the canvas's drop code. The previous folder setting is restored.
    private static func runStrip(folder: URL, record: (String, Bool, String) -> Void) async throws {
        let model = CanvasModel.shared
        let strip = MediaStrip.shared
        let defaults = UserDefaults.standard
        let savedFolder = defaults.string(forKey: "strip.folderPath")
        let savedVisible = defaults.object(forKey: "strip.visible")
        defer {
            if let savedFolder { defaults.set(savedFolder, forKey: "strip.folderPath") }
            else { defaults.removeObject(forKey: "strip.folderPath") }
            if let savedVisible { defaults.set(savedVisible, forKey: "strip.visible") }
            else { defaults.removeObject(forKey: "strip.visible") }
        }

        model.removeAll()
        strip.setFolder(folder)
        await strip.waitForScan()
        strip.hiddenForCapture = false // showing only the test folder now
        defer { strip.hiddenForCapture = true }
        let result = strip.result
        let names = result?.sections.flatMap { $0.items.map(\.name) } ?? []
        record("strip scans folder and subfolders",
               (result?.count ?? 0) >= 4 && (result?.sections.count ?? 0) >= 2 && (result?.videoCount ?? 0) >= 1,
               "items=\(result?.count ?? 0) sections=\(result?.sections.map { $0.relativeFolder.isEmpty ? "(root)" : $0.relativeFolder } ?? []) videos=\(result?.videoCount ?? 0) names=\(names)")

        // The strip is in the window, to the left of the canvas.
        try await Task.sleep(for: .milliseconds(600))
        guard let canvasView = InteractionNSView.current, let window = canvasView.window else {
            throw Failure(description: "canvas view missing")
        }
        let canvasFrame = canvasView.convert(canvasView.bounds, to: nil)
        record("strip sits left of the canvas", strip.isVisible && canvasFrame.minX >= 140,
               "canvas starts at x=\(Int(canvasFrame.minX)) of window width \(Int(window.frame.width))")

        // Fill the canvas with two items, then drag a third from the strip onto the left edge.
        let all = result?.sections.flatMap(\.items) ?? []
        guard all.count >= 3 else { throw Failure(description: "need 3+ items in strip folder") }
        model.add(urls: [all[0].url, all[1].url])
        try await Task.sleep(for: .milliseconds(400))

        // What the strip's drag provider actually carries, loaded the way a drop destination
        // does, then written to a pasteboard and read back by the canvas's drop code.
        let provider = StripCell.dragProvider(for: all[2].url)
        let providerTypes = provider.registeredTypeIdentifiers
        let loaded: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ImageCanvas.selftest.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let wrote = loaded.map { pasteboard.writeObjects([$0 as NSURL]) } ?? false
        let read = InteractionNSView.fileURLs(on: pasteboard)
        pasteboard.releaseGlobally()
        record("strip drag carries the file", wrote && read == [all[2].url]
                   && providerTypes.contains("public.file-url"),
               "providerTypes=\(providerTypes) loaded=\(loaded?.lastPathComponent ?? "nil") readBack=\(read.map(\.lastPathComponent))")

        let dropPoint = CGPoint(x: 3, y: model.canvasSize.height / 2)
        canvasView.simulateDrop(of: read, at: dropPoint)
        try await Task.sleep(for: .milliseconds(400))
        let added = model.tiles.values.first { $0.url == all[2].url }
        let addedRect = added.flatMap { model.frames()[$0.id] }
        record("dropping a strip item on the canvas adds it where dropped",
               model.tiles.count == 3 && addedRect.map { $0.minX < 1 } == true,
               "tiles=\(model.tiles.count) newPane=\(addedRect.map { "\($0)" } ?? "nil")")

        // Double-click alternative: adding directly also works.
        model.add(urls: [all[0].url])
        try await Task.sleep(for: .milliseconds(200))
        record("adding from the strip again adds another pane", model.tiles.count == 4, "tiles=\(model.tiles.count)")
    }

    /// Mouse hover shows the video bar; clicking and dragging on its track seeks.
    /// Uses real NSEvents sent through the window, like the click checks.
    private static func runHoverSeek(video: URL, record: (String, Bool, String) -> Void) async throws {
        let model = CanvasModel.shared
        model.removeAll()
        model.add(urls: [video])
        for _ in 0..<100 where !(model.tiles.values.first?.video.map { $0.duration > 0 } ?? false) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let view = InteractionNSView.current, let window = view.window,
              let id = model.layout?.ids.first, let player = model.tiles[id]?.video,
              let bar = model.videoBar(for: id), let pane = model.paneRect(id) else {
            throw Failure(description: "video never loaded")
        }
        try await Task.sleep(for: .milliseconds(300))
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .mouseMoved { view.mouseMoved(with: event) } else { window.sendEvent(event) }
        }

        // Runtime always known; the bar layout has room for times on a pane this size.
        record("video pane has runtime and full bar layout",
               bar.durationLabel != nil && bar.currentLabel != nil && player.duration > 9,
               String(format: "duration=%.2f runtime=%@ pane=%.0fx%.0f", player.duration,
                      ScrubMath.timecode(player.duration), pane.width, pane.height))

        // Hovering marks the pane hovered (the bar is drawn for the hovered pane).
        send(.mouseMoved, CGPoint(x: pane.midX, y: pane.midY))
        let hovered = model.hoveredID == id
        send(.mouseMoved, CGPoint(x: -50, y: -50))
        view.mouseExited(with: NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 0, pressure: 0)!)
        let unhovered = model.hoveredID == nil
        record("hover shows the bar; leaving hides it", hovered && unhovered,
               "hovered=\(hovered) clearedOnExit=\(unhovered)")

        // Click on the track at 25%: jumps there, pauses while held; drag to 75%; release resumes.
        send(.mouseMoved, CGPoint(x: pane.midX, y: pane.midY))
        let x25 = bar.track.minX + bar.track.width * 0.25, x75 = bar.track.minX + bar.track.width * 0.75
        let layoutBefore = model.layout
        send(.leftMouseDown, CGPoint(x: x25, y: bar.track.midY + 6))
        let downTime = model.scrub?.time ?? -1
        let pausedWhileHeld = player.player.rate == 0
        for i in 1...8 {
            send(.leftMouseDragged, CGPoint(x: x25 + (x75 - x25) * CGFloat(i) / 8, y: bar.track.midY))
        }
        let dragTime = model.scrub?.time ?? -1
        try await Task.sleep(for: .milliseconds(400))
        let playerAtDrag = player.currentSeconds
        send(.leftMouseUp, CGPoint(x: x75, y: bar.track.midY))
        try await Task.sleep(for: .milliseconds(200))
        let d = player.duration
        let ok = abs(downTime - d * 0.25) < 0.05 && abs(dragTime - d * 0.75) < 0.05
            && abs(playerAtDrag - dragTime) < 0.1 && pausedWhileHeld
            && model.scrub == nil && player.player.rate > 0 && model.layout == layoutBefore && model.draggingID == nil
        record("click and drag on the seek bar seeks without moving the pane", ok,
               String(format: "down=%.2f (want %.2f) drag=%.2f (want %.2f) player=%.2f pausedWhileHeld=%@ resumed=%@ paneMoved=%@",
                      downTime, d * 0.25, dragTime, d * 0.75, playerAtDrag, "\(pausedWhileHeld)",
                      "\(player.player.rate > 0)", "\(model.layout != layoutBefore)"))

        // Play/pause button in the bar still works.
        if let play = bar.playPause {
            send(.leftMouseDown, CGPoint(x: play.midX, y: play.midY))
            send(.leftMouseUp, CGPoint(x: play.midX, y: play.midY))
            let paused = !player.isPlaying && player.player.rate == 0
            send(.leftMouseDown, CGPoint(x: play.midX, y: play.midY))
            send(.leftMouseUp, CGPoint(x: play.midX, y: play.midY))
            record("play/pause button in the bar toggles", paused && player.isPlaying,
                   "pausedAfterFirst=\(paused) playingAfterSecond=\(player.isPlaying)")
        }
    }

    /// Two-finger scrub, driven through the same handler `scrollWheel(with:)` calls.
    /// Deltas are in finger direction (positive x = fingers moving right).
    private static func runScrub(video: URL, record: (String, Bool, String) -> Void) async throws {
        let model = CanvasModel.shared
        model.removeAll()
        model.add(urls: [video])
        for _ in 0..<100 where !(model.tiles.values.first?.video.map { $0.duration > 0 } ?? false) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let view = InteractionNSView.current, let id = model.layout?.ids.first,
              let player = model.tiles[id]?.video, let pane = model.paneRect(id) else {
            throw Failure(description: "video never loaded")
        }
        try await Task.sleep(for: .milliseconds(500))
        let p = CGPoint(x: pane.midX, y: pane.midY)
        func scroll(_ phase: NSEvent.Phase, momentum: Bool = false, dx: CGFloat, dy: CGFloat = 0) -> Bool {
            view.handleTrackpadScroll(phase: phase, isMomentum: momentum,
                                      contentDelta: CGSize(width: dx, height: dy),
                                      fingerDelta: CGSize(width: dx, height: dy), at: p, command: false)
        }

        // Fingers down: no seek bar until the swipe direction is known.
        _ = scroll(.mayBegin, dx: 0)
        _ = scroll(.began, dx: 1)
        let hiddenAtStart = model.scrub == nil
        // Sideways swipe: the bar appears, playback pauses and time follows the fingers.
        _ = scroll(.changed, dx: 6)
        let shownAfterSwipe = model.scrub?.id == id
        let start = model.scrub?.time ?? 0
        for _ in 0..<10 { _ = scroll(.changed, dx: 20, dy: 3) } // a little vertical drift
        let expected = ScrubMath.advance(start, by: 200, paneWidth: pane.width, duration: player.duration)
        let forward = model.scrub?.time ?? -1
        let paused = player.player.rate == 0
        try await Task.sleep(for: .milliseconds(400))
        let playerTime = player.currentSeconds
        // Swipe left goes back.
        for _ in 0..<5 { _ = scroll(.changed, dx: -20) }
        let back = model.scrub?.time ?? -1
        record("two-finger sideways swipe shows seek bar and scrubs", hiddenAtStart && shownAfterSwipe
                   && abs(forward - expected) < 0.001 && back < forward && paused,
               String(format: "hiddenAtStart=%@ shown=%@ start=%.2f forward=%.2f expected=%.2f back=%.2f paused=%@",
                      "\(hiddenAtStart)", "\(shownAfterSwipe)", start, forward, expected, back, "\(paused)"))
        record("player follows the scrub", abs(playerTime - forward) < 0.1,
               String(format: "player=%.3f scrub=%.3f", playerTime, forward))

        // Fingers lift: the bar goes immediately; coasting events neither seek nor bring it back.
        _ = scroll(.ended, dx: 0)
        let hiddenOnLift = model.scrub == nil
        let resumed = player.player.rate > 0
        let timeAtLift = player.currentSeconds
        for _ in 0..<8 {
            _ = scroll([], momentum: true, dx: 30)
        }
        let staysHidden = model.scrub == nil
        try await Task.sleep(for: .milliseconds(300))
        record("lifting fingers hides seek bar at once and resumes", hiddenOnLift && staysHidden && resumed,
               "hiddenOnLift=\(hiddenOnLift) staysHiddenThroughMomentum=\(staysHidden) resumed=\(resumed) timeAtLift=\(timeAtLift)")

        // A vertical swipe on an unzoomed video is not a scrub.
        _ = scroll(.began, dx: 0, dy: 1)
        _ = scroll(.changed, dx: 1, dy: 8)
        let noScrubVertical = model.scrub == nil
        _ = scroll(.ended, dx: 0)
        record("vertical two-finger swipe does not scrub", noScrubVertical, "scrub=\(String(describing: model.scrub))")
    }

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
        // The mouse checks below assume four equal quadrants.
        model.evenOut()
        try await Task.sleep(for: .milliseconds(450))
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
