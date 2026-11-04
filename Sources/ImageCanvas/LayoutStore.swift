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

    /// The saved layout the canvas came from (opened or last saved), so saving again
    /// offers to overwrite it. Cleared when the canvas is cleared or the last view restored.
    private(set) var currentName: String?

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
        currentName = document.name
        refresh()
        return url
    }

    func load(_ entry: Entry) throws -> LayoutDocument {
        try LayoutDocument.decode(Data(contentsOf: entry.url))
    }

    /// The canvas no longer matches a saved layout (cleared, or replaced by the last view).
    func forgetCurrent() {
        currentName = nil
    }

    // MARK: Save dialog logic (kept separate from the dialog so the self-test can check it)

    /// The name the save dialog starts with: the layout that was opened or last saved, if
    /// its file still exists; otherwise a new dated name.
    func defaultSaveName(now: Date = Date()) -> String {
        if let currentName, FileManager.default.fileExists(atPath: fileURL(forName: currentName).path) {
            return currentName
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Layout \(formatter.string(from: now))"
    }

    struct SaveTarget: Equatable {
        /// The name the file will have.
        let name: String
        /// An existing layout this save will overwrite, and when that was last saved.
        let overwrites: Date?
        var willOverwrite: Bool { overwrites != nil }
    }

    func saveTarget(for typed: String) -> SaveTarget {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Layout" : trimmed
        let url = fileURL(forName: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return SaveTarget(name: name, overwrites: nil) }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return SaveTarget(name: name, overwrites: modified ?? .distantPast)
    }

    // MARK: UI

    /// File > Save Layout (Cmd-S). After opening a saved layout, the name is already filled
    /// in and Return overwrites it; the dialog says so plainly, and updates as you type.
    func promptSave(_ model: CanvasModel) {
        let dialog = SaveLayoutDialog(store: self, initialName: defaultSaveName())
        guard let target = dialog.run() else { return }
        do {
            try save(model.makeDocument(name: target.name))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(_ entry: Entry, into model: CanvasModel) {
        do {
            let missing = model.apply(try load(entry))
            currentName = entry.name
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

private extension String {
    /// "Today at 2:14 PM" reads better mid-sentence as "today at 2:14 PM".
    func lowercasedFirstWordIfRelative() -> String {
        for word in ["Today", "Yesterday"] where hasPrefix(word) {
            return word.lowercased() + dropFirst(word.count)
        }
        return self
    }
}

/// The Save Layout dialog. Shows, live as you type, whether the save creates a new layout
/// or overwrites an existing one, and names the button to match ("Overwrite" vs "Save").
@MainActor
private final class SaveLayoutDialog: NSObject {
    private let store: LayoutStore
    private let alert = NSAlert()
    private let field = NSTextField(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private var observer: NSObjectProtocol?

    init(store: LayoutStore, initialName: String) {
        self.store = store
        super.init()
        alert.messageText = "Save Layout"
        alert.informativeText = "Saves which files are open, where each pane sits and how far each is zoomed."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        field.stringValue = initialName
        field.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.preferredMaxLayoutWidth = 280
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)

        let statusRow = NSStackView(views: [icon, status])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 4
        let stack = NSStackView(views: [field, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 62)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: field, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let target = store.saveTarget(for: field.stringValue)
        let button = alert.buttons[0]
        if let date = target.overwrites {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true // "Today at 2:14 PM"
            let when = formatter.string(from: date).lowercasedFirstWordIfRelative()
            button.title = "Overwrite"
            button.hasDestructiveAction = true
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            icon.contentTintColor = .systemOrange
            status.stringValue = "Overwrites the saved layout “\(target.name)” (last saved \(when)). Change the name to save a new one instead."
            status.textColor = .systemOrange
        } else {
            button.title = "Save"
            button.hasDestructiveAction = false
            icon.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "New")
            icon.contentTintColor = .secondaryLabelColor
            status.stringValue = "Saves a new layout named “\(target.name)”."
            status.textColor = .secondaryLabelColor
        }
    }

    /// Returns where to save, or nil if cancelled.
    func run() -> LayoutStore.SaveTarget? {
        defer { if let observer { NotificationCenter.default.removeObserver(observer) } }
        alert.layout()
        // Select the name so typing replaces it, while Return keeps (and overwrites) it.
        DispatchQueue.main.async { [field] in field.currentEditor()?.selectAll(nil) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return store.saveTarget(for: field.stringValue)
    }
}
