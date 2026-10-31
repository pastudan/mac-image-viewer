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
        // every image just joins the one canvas.
        Window("Image Canvas", id: "canvas") {
            CanvasView(model: model)
                .navigationTitle(title)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Make Default Image Viewer…") { DefaultHandler.makeDefault() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Remove Selected Image") { model.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedID == nil)
                Button("Clear Canvas") { model.removeAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.tiles.isEmpty)
            }
            CommandMenu("Arrange") {
                Button("Tile All") { withAnimation(.spring(duration: 0.3)) { model.tileAll() } }
                    .keyboardShortcut("g")
                    .disabled(model.tiles.isEmpty)
                Divider()
                ForEach(snapShortcuts, id: \.zone) { item in
                    Button("Snap Selected: \(item.zone.title)") {
                        guard let id = model.selectedID else { return }
                        withAnimation(.spring(duration: 0.25)) { model.snap(id, to: item.zone) }
                    }
                    .keyboardShortcut(item.key, modifiers: [.control, .option])
                    .disabled(model.selectedID == nil)
                }
            }
        }
    }

    private var title: String {
        switch model.tiles.count {
        case 0: "Image Canvas"
        case 1: model.tiles[0].name
        default: "Image Canvas — \(model.tiles.count) images"
        }
    }

    /// Ctrl-Opt + arrows/letters, mirroring Rectangle/Magnet conventions.
    private var snapShortcuts: [(zone: SnapZone, key: KeyEquivalent)] {
        [
            (.leftHalf, .leftArrow), (.rightHalf, .rightArrow),
            (.topHalf, .upArrow), (.bottomHalf, .downArrow),
            (.topLeft, "u"), (.topRight, "i"), (.bottomLeft, "j"), (.bottomRight, "k"),
            (.full, .return),
        ]
    }

    @MainActor
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
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
        // Let the window appear first, then (once) offer to take over image files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { DefaultHandler.offerOnFirstLaunch() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
