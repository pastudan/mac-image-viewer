import AppKit
import CanvasCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct ImageCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = CanvasModel.shared
    @State private var layouts = LayoutStore.shared
    @State private var lock = AppLock.shared
    @State private var strip = MediaStrip.shared
    @State private var lastView = LastView.shared

    var body: some Scene {
        // A single `Window` (not WindowGroup): opening more files never spawns new windows,
        // everything joins the one canvas.
        Window("Image Canvas", id: "canvas") {
            HStack(spacing: 0) {
                if strip.isShown {
                    StripView(strip: strip, model: model)
                        .frame(width: strip.width)
                    StripResizeHandle(strip: strip)
                }
                CanvasView(model: model)
                    .frame(minWidth: 320)
                    .layoutPriority(1)
            }
            .animation(.easeOut(duration: 0.18), value: strip.isVisible)
            .toolbar {
                // Title-bar button that hides and shows the strip; always there, so a hidden
                // strip is one click away.
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { strip.isVisible.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(strip.isVisible ? "Hide strip (Control-Command-S)" : "Show strip (Control-Command-S)")
                }
            }
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle(title)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Make Default Viewer…") { DefaultHandler.makeDefault() }
                Button("Clear for Privacy") { lock.clearNow() }
                    .keyboardShortcut("l", modifiers: [.control, .command])
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openPanel() }
                    .keyboardShortcut("o")
                Button("Restore Last View") { Task { await lastView.restore() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(lastView.isRestoring)
                Button("Choose Strip Folder…") { strip.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .sidebar) {
                Button(strip.isVisible ? "Hide Strip" : "Show Strip") { strip.isVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Rescan Strip Folder") { strip.rescan() }
                    .disabled(strip.folder == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Layout…") { layouts.promptSave(model) }
                    .keyboardShortcut("s")
                    .disabled(model.isEmpty)
                Menu("Open Layout") {
                    if layouts.entries.isEmpty {
                        Text("No Saved Layouts")
                    }
                    ForEach(layouts.entries) { entry in
                        Button(entry.name) { layouts.open(entry, into: model) }
                    }
                    Divider()
                    Button("Refresh List") { layouts.refresh() }
                }
                Button("Show Layouts Folder") { layouts.revealFolder() }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Remove Selected") { model.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedID == nil)
                Button("Clear Canvas") { model.removeAll(); layouts.forgetCurrent() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Crop to Fill Panes", isOn: Binding(
                    get: { model.cropToFill },
                    set: { model.cropToFill = $0; if model.layoutIsAuto { model.refit(animated: true) } }))
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Zoom In") { model.zoomSelected(by: 1.25) }
                    .keyboardShortcut("=")
                    .disabled(model.selectedID == nil)
                Button("Zoom Out") { model.zoomSelected(by: 0.8) }
                    .keyboardShortcut("-")
                    .disabled(model.selectedID == nil)
                Button("Actual Size") { if let id = model.selectedID { model.resetZoom(id) } }
                    .keyboardShortcut("0")
                    .disabled(model.selectedID == nil)
                Divider()
            }
            CommandMenu("Arrange") {
                Button("Best Fit") { model.refit(animated: true) }
                    .keyboardShortcut("g")
                    .disabled(model.isEmpty)
                Button("Even Out") { model.evenOut() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.isEmpty)
                Button(model.expandedID == nil ? "Expand Selected to Fill Window" : "Return to Layout") {
                    if model.expandedID != nil { model.collapse() }
                    else if let id = model.selectedID { model.toggleExpand(id) }
                }
                .keyboardShortcut(.return, modifiers: [.control, .option])
                .disabled(model.selectedID == nil && model.expandedID == nil)
                Divider()
                ForEach(snapShortcuts, id: \.zone) { item in
                    Button("Snap Selected: \(item.zone.title)") {
                        guard let id = model.selectedID else { return }
                        model.snap(id, to: item.zone)
                    }
                    .keyboardShortcut(item.key, modifiers: [.control, .option])
                    .disabled(model.selectedID == nil)
                }
            }
            CommandMenu("Playback") {
                Button(model.selectedVideo?.isPlaying == false ? "Play" : "Pause") {
                    if let id = model.selectedID { model.togglePlay(id) }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedVideo == nil)
                Button(model.selectedVideo?.isMuted == false ? "Mute" : "Unmute") {
                    if let id = model.selectedID { model.toggleMute(id) }
                }
                .keyboardShortcut("m", modifiers: [])
                .disabled(model.selectedVideo == nil)
            }
        }

        Settings {
            SettingsView(lock: lock, model: model)
        }
    }

    private var title: String {
        let tiles = Array(model.tiles.values)
        switch tiles.count {
        case 0: return "Image Canvas"
        case 1: return tiles[0].name
        default: return "Image Canvas — \(tiles.count) items"
        }
    }

    /// Ctrl-Opt + arrows/letters, mirroring Rectangle/Magnet conventions.
    private var snapShortcuts: [(zone: SnapZone, key: KeyEquivalent)] {
        [
            (.leftHalf, .leftArrow), (.rightHalf, .rightArrow),
            (.topHalf, .upArrow), (.bottomHalf, .downArrow),
            (.topLeft, "u"), (.topRight, "i"), (.bottomLeft, "j"), (.bottomRight, "k"),
        ]
    }

    @MainActor
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder double-click (cold launch or already running) and `open -a` land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            CanvasModel.shared.add(urls: urls)
        }
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppLock.shared.startObserving() }
        if CommandLine.arguments.contains("--self-test") {
            MainActor.assumeIsolated { SelfTest.runIfRequested() }
            return
        }
        // Let the window appear first, then (once) offer to take over image and video files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { DefaultHandler.offerOnFirstLaunch() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--self-test") else { return }
        MainActor.assumeIsolated { LastView.shared.saveNow() }
    }
}
