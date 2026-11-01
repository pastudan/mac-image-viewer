import Foundation
import UniformTypeIdentifiers

/// One image or video found under a strip folder.
public struct ScannedMedia: Hashable, Sendable, Identifiable {
    public let url: URL
    public let isVideo: Bool
    /// Folder path relative to the scanned root ("" for the root itself), "/"-separated.
    public let relativeFolder: String

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// The media in one folder, in display order.
public struct ScannedSection: Hashable, Sendable, Identifiable {
    public let relativeFolder: String
    public let items: [ScannedMedia]
    public var id: String { relativeFolder }
}

public struct FolderScanResult: Equatable, Sendable {
    public let root: URL
    /// Root folder first, then subfolders in Finder order ("Day 2" before "Day 10").
    public let sections: [ScannedSection]
    /// True when the scan stopped at the item limit.
    public let truncated: Bool

    public var count: Int { sections.reduce(0) { $0 + $1.items.count } }
    public var videoCount: Int { sections.reduce(0) { $0 + $1.items.filter(\.isVideo).count } }
    public var imageCount: Int { count - videoCount }
}

public enum FolderScanner {
    /// Stop after this many items so a huge folder can't stall the app.
    public static let defaultLimit = 20_000

    /// Whether a file type is something the canvas shows: an image, or a video (`true`).
    public static func classify(_ type: UTType) -> Bool? {
        if type.conforms(to: .image) { return false }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        return nil
    }

    /// Recursively finds images and videos under `root`. Skips hidden files and the insides
    /// of packages (apps, Photos libraries). Call off the main thread.
    public static func scan(_ root: URL, limit: Int = defaultLimit,
                            shouldContinue: () -> Bool = { true }) -> FolderScanResult {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return FolderScanResult(root: root, sections: [], truncated: false)
        }

        let rootComponents = root.standardizedFileURL.pathComponents
        let resolvedRootComponents = root.resolvingSymlinksInPath().pathComponents
        func relativeFolder(of url: URL) -> String {
            let parent = url.deletingLastPathComponent()
            let components = parent.standardizedFileURL.pathComponents
            if components.starts(with: rootComponents) {
                return components.dropFirst(rootComponents.count).joined(separator: "/")
            }
            let resolved = parent.resolvingSymlinksInPath().pathComponents
            if resolved.starts(with: resolvedRootComponents) {
                return resolved.dropFirst(resolvedRootComponents.count).joined(separator: "/")
            }
            return parent.lastPathComponent
        }

        var byFolder: [String: [ScannedMedia]] = [:]
        var count = 0
        var truncated = false
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 256 == 0, !shouldContinue() { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension),
                  let isVideo = classify(type) else { continue }
            guard count < limit else {
                truncated = true
                break
            }
            let folder = relativeFolder(of: url)
            byFolder[folder, default: []].append(ScannedMedia(url: url, isVideo: isVideo, relativeFolder: folder))
            count += 1
        }

        let sections = byFolder.keys
            .sorted { a, b in
                if a.isEmpty != b.isEmpty { return a.isEmpty }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { folder in
                ScannedSection(relativeFolder: folder, items: byFolder[folder]!.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                })
            }
        return FolderScanResult(root: root, sections: sections, truncated: truncated)
    }
}
