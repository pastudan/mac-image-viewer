import AppKit
import CanvasCore
import Observation
import QuickLookThumbnailing

/// The folder shown in the left-hand strip: its scanned contents and the strip's visibility.
@MainActor
@Observable
final class MediaStrip {
    static let shared = MediaStrip()

    private enum Key {
        static let folder = "strip.folderPath"
        static let visible = "strip.visible"
        static let width = "strip.width"
    }

    static let widthRange: ClosedRange<CGFloat> = 150...520

    /// Strip width in points; drag the bar between strip and canvas to change it.
    var width: CGFloat {
        didSet {
            let clamped = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            if clamped != width { width = clamped; return }
            UserDefaults.standard.set(Double(width), forKey: Key.width)
        }
    }

    /// Hides the strip without touching the saved setting (self-test screenshots only:
    /// the strip may show the user's own private folder).
    var hiddenForCapture = false
    var isShown: Bool { isVisible && !hiddenForCapture }

    private(set) var folder: URL?
    private(set) var result: FolderScanResult?
    private(set) var isScanning = false
    /// Hidden at every launch; shown only when asked (View > Show Strip, choosing a folder,
    /// or Restore Last View). Whether it was showing is part of the saved last view.
    var isVisible = false {
        didSet {
            if isVisible { start() }
            if isVisible != oldValue { LastView.shared.noteChange() }
        }
    }

    private var scanTask: Task<Void, Never>?
    private var generation = 0

    init() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.visible) // no longer persisted: the app opens empty
        let savedWidth = defaults.object(forKey: Key.width) as? Double ?? 240
        width = min(max(CGFloat(savedWidth), Self.widthRange.lowerBound), Self.widthRange.upperBound)
        // The folder is never remembered in plain preferences. It's kept only in the last-view
        // file and comes back behind Touch ID. Move an old plain setting there once, then drop it.
        if let path = defaults.string(forKey: Key.folder) {
            LastView.shared.rememberStripFolder(path)
            defaults.removeObject(forKey: Key.folder)
        }
    }

    /// Scans the current folder if it hasn't been yet.
    func start() {
        if folder != nil, result == nil, !isScanning { rescan() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Show in Strip"
        panel.message = "Choose a folder. Its images and videos, including those in subfolders, appear in the strip."
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        folder = url
        LastView.shared.rememberStripFolder(url.path)
        isVisible = true
        rescan()
    }

    /// Hides the strip and forgets the folder and its listing for this session (privacy
    /// clear). The folder can come back via Restore Last View / Restore Last Folder.
    func close() {
        scanTask?.cancel()
        generation += 1
        isVisible = false
        folder = nil
        result = nil
        isScanning = false
    }

    /// Re-reads the folder (also picks up files added since).
    func rescan() {
        guard let folder else { return }
        scanTask?.cancel()
        generation += 1
        let token = generation
        isScanning = true
        scanTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(folder, shouldContinue: { !Task.isCancelled })
            }.value
            guard token == self.generation else { return } // a newer scan replaced this one
            self.result = result
            self.isScanning = false
        }
    }

    /// Waits for the current scan; used by the self-test.
    func waitForScan() async {
        await scanTask?.value
    }
}

/// Small cached thumbnails for the strip, made by Quick Look (works for images and videos).
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 600
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Drops every thumbnail held in memory (privacy clear).
    func removeAll() {
        cache.removeAllObjects()
    }

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: scale, representationTypes: .thumbnail)
            let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return rep?.nsImage
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
