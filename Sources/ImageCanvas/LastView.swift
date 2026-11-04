import AppKit
import CanvasCore
import Observation

/// The previous session's view, saved continuously and only brought back on request,
/// behind Touch ID. The app always opens empty: no canvas, no strip.
///
/// Stored as JSON in ~/Library/Application Support/Image Canvas/Last View.json, the same
/// place as saved layouts. It records file paths and arrangement, not the images themselves.
@MainActor
@Observable
final class LastView {
    static let shared = LastView()

    struct Snapshot: Codable, Equatable {
        var document: LayoutDocument
        var stripVisible: Bool
        var stripFolder: String?
    }

    private(set) var isRestoring = false
    private(set) var message: String?

    /// Replaceable for the self-test, which can't touch the sensor.
    var authenticator: (String) async -> AppLock.AuthResult = AppLock.systemAuthenticate
    /// Where the snapshot lives; the self-test points this at a scratch file.
    var fileURL: URL

    /// Snapshots aren't written until the user has done something this session, so
    /// opening the app empty and quitting doesn't erase the previous view.
    private var armed = false
    private var saveTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("Image Canvas/Last View.json")
    }

    var hasSnapshot: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: Saving

    /// Something changed in this session; save shortly (coalesced).
    func noteChange() {
        armed = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Writes the snapshot immediately (also on quit). An empty canvas with no strip
    /// leaves the previous snapshot alone.
    func saveNow() {
        saveTask?.cancel()
        guard armed else { return }
        let model = CanvasModel.shared
        let strip = MediaStrip.shared
        guard !model.isEmpty || strip.isVisible else { return }
        let snapshot = Snapshot(document: model.makeDocument(name: "Last View"),
                                stripVisible: strip.isVisible,
                                stripFolder: strip.folder?.path)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            NSLog("Image Canvas: could not save last view: \(error.localizedDescription)")
        }
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    // MARK: Restoring

    /// File > Restore Last View: Touch ID first, then bring the canvas and strip back.
    func restore() async {
        guard !isRestoring, !AppLock.shared.isLocked else { return }
        guard let snapshot = load() else {
            message = "There's no previous view to restore."
            showMessage()
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        switch await authenticator("restore your last view") {
        case .success:
            apply(snapshot)
            message = nil
        case .cancelled:
            message = nil
        case .failed(let reason):
            message = reason
            showMessage()
        }
    }

    private func apply(_ snapshot: Snapshot) {
        let strip = MediaStrip.shared
        if let path = snapshot.stripFolder, FileManager.default.fileExists(atPath: path) {
            if strip.folder?.path != path { strip.setFolder(URL(fileURLWithPath: path, isDirectory: true)) }
        }
        strip.isVisible = snapshot.stripVisible
        if !snapshot.document.items.isEmpty {
            LayoutStore.shared.forgetCurrent()
            let missing = CanvasModel.shared.apply(snapshot.document)
            if !missing.isEmpty {
                NSLog("Image Canvas: \(missing.count) file(s) from the last view are missing")
            }
        }
        armed = true
    }

    private func showMessage() {
        guard let message, !CommandLine.arguments.contains("--self-test") else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't restore the last view"
        alert.informativeText = message
        alert.runModal()
    }

    /// Forget the saved view (e.g. after restoring is no longer wanted).
    func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
