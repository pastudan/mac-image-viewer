import AppKit
import CanvasCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct ImageCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = CanvasModel.shared

    var body: some Scene {
        // A single `Window` (not WindowGroup): opening more files never spawns new windows,
        // everything joins the one canvas.
        Window("Image Canvas", id: "canvas") {
            CanvasView(model: model)
                .navigationTitle(title)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Make Default Viewer…") { DefaultHandler.makeDefault() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Remove Selected") { model.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedID == nil)
                Button("Clear Canvas") { model.removeAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Crop to Fill Panes", isOn: $model.cropToFill)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
            }
            CommandMenu("Arrange") {
                Button("Even Out") { model.evenOut() }
                    .keyboardShortcut("g")
                    .disabled(model.isEmpty)
                Button(model.zoomedID == nil ? "Zoom Selected" : "Exit Zoom") {
                    if model.zoomedID != nil { model.exitZoom() }
                    else if let id = model.selectedID { model.toggleZoom(id) }
                }
                .keyboardShortcut(.return, modifiers: [.control, .option])
                .disabled(model.selectedID == nil && model.zoomedID == nil)
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
        // Let the window appear first, then (once) offer to take over image and video files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { DefaultHandler.offerOnFirstLaunch() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
