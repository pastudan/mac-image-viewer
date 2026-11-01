import CoreGraphics
import Foundation

/// A saved canvas: which files were open, where each pane sat, and each pane's zoom.
/// Stored as JSON. Leaves in `layout` are indexes into `items`.
public struct LayoutDocument: Codable, Equatable {
    public struct Item: Codable, Equatable {
        public var path: String
        public var zoom: ZoomTransform

        public init(path: String, zoom: ZoomTransform = .identity) {
            self.path = path
            self.zoom = zoom
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var savedAt: Date
    public var cropToFill: Bool
    public var items: [Item]
    public var layout: LayoutNode<Int>?

    public init(name: String, savedAt: Date, cropToFill: Bool, items: [Item], layout: LayoutNode<Int>?) {
        self.version = Self.currentVersion
        self.name = name
        self.savedAt = savedAt
        self.cropToFill = cropToFill
        self.items = items
        self.layout = layout
    }

    /// Builds a document from a live layout. `item` describes each tile; tiles it returns
    /// nil for are left out.
    public init<K: Hashable>(name: String, savedAt: Date, cropToFill: Bool,
                             layout: LayoutNode<K>?, item: (K) -> Item?) {
        var items: [Item] = []
        var index: [K: Int] = [:]
        for key in layout?.ids ?? [] {
            guard let it = item(key) else { continue }
            index[key] = items.count
            items.append(it)
        }
        self.init(name: name, savedAt: savedAt, cropToFill: cropToFill, items: items,
                  layout: layout?.compactMapIDs { index[$0] })
    }

    public static func decode(_ data: Data) throws -> LayoutDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LayoutDocument.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// A file name for `name` that is safe on macOS.
    public static func fileName(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? "Layout" : cleaned) + ".json"
    }
}
