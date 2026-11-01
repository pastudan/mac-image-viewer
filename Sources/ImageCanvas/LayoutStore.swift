import AppKit
import CanvasCore
import Observation

/// Saved layouts: one JSON file each in ~/Library/Application Support/Image Canvas/Layouts.
@MainActor
@Observable
final class LayoutStore {
    static let shared = LayoutStore()

    struct Entry: Identifiable, Hashable {
        let url: URL
        let name: String
        let modified: Date
        var id: URL { url }
    }

    private(set) var entries: [Entry] = []
    var directory: URL {
        didSet { refresh() }
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Image Canvas/Layouts", isDirectory: true)
        refresh()
    }

    /// Re-reads the folder, newest first. Picks up files added or deleted in Finder.
    func refresh() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        entries = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                return Entry(url: url, name: url.deletingPathExtension().lastPathComponent, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    func fileURL(forName name: String) -> URL {
        directory.appendingPathComponent(LayoutDocument.fileName(for: name))
    }

    @discardableResult
    func save(_ document: LayoutDocument) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(forName: document.name)
        try document.encoded().write(to: url, options: .atomic)
        refresh()
        return url
    }

    func load(_ entry: Entry) throws -> LayoutDocument {
        try LayoutDocument.decode(Data(contentsOf: entry.url))
    }

    // MARK: UI

    /// Asks for a name and saves the current canvas.
    func promptSave(_ model: CanvasModel) {
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Saves which files are open, where each pane sits and how far each is zoomed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        field.stringValue = "Layout \(formatter.string(from: Date()))"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = fileURL(forName: name)
        if FileManager.default.fileExists(atPath: url.path) {
            let replace = NSAlert()
            replace.messageText = "Replace “\(url.deletingPathExtension().lastPathComponent)”?"
            replace.informativeText = "A layout with that name already exists."
            replace.addButton(withTitle: "Replace")
            replace.addButton(withTitle: "Cancel")
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try save(model.makeDocument(name: name.isEmpty ? "Layout" : name))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(_ entry: Entry, into model: CanvasModel) {
        do {
            let missing = model.apply(try load(entry))
            guard !missing.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = missing.count == 1 ? "1 file is missing" : "\(missing.count) files are missing"
            alert.informativeText = "These were moved or deleted since the layout was saved, so their panes were left out:\n\n"
                + missing.prefix(8).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
