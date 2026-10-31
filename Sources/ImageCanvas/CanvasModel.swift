import AppKit
import CanvasCore
import Observation

@MainActor
@Observable
final class CanvasModel {
    static let shared = CanvasModel()

    /// Array order is z-order: last is on top.
    private(set) var tiles: [Tile] = []
    var selectedID: UUID?
    /// Zone highlighted while a tile is being dragged over it.
    var snapPreview: SnapZone?
    /// Current canvas size in points, kept up to date by CanvasView.
    var canvasSize: CGSize = CGSize(width: 1200, height: 800)

    private var cascadeIndex = 0

    // MARK: Adding and removing

    /// Adds images as new tiles. `point` (canvas points) centres them on a drop location.
    func add(urls: [URL], at point: CGPoint? = nil) {
        let images = urls.filter(ImageLoader.isImage)
        guard !images.isEmpty else { return }
        for url in images {
            Task {
                let cg = await Task.detached(priority: .userInitiated) { ImageLoader.load(url) }.value
                guard let cg else {
                    NSLog("Image Canvas: could not decode \(url.path)")
                    return
                }
                insert(url: url, cgImage: cg, at: point)
            }
        }
    }

    private func insert(url: URL, cgImage: CGImage, at point: CGPoint?) {
        let aspect = CGFloat(cgImage.width) / CGFloat(max(cgImage.height, 1))
        let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))

        let size = canvasSize
        let pts = CanvasLayout.fit(aspect: aspect, in: CGSize(width: size.width * 0.5, height: size.height * 0.5))
        let center: CGPoint
        if let point {
            center = point
        } else {
            let step = CGFloat(cascadeIndex % 8) * 28
            cascadeIndex += 1
            center = CGPoint(x: size.width / 2 + step - 98, y: size.height / 2 + step - 98)
        }
        var rect = CGRect(x: center.x - pts.width / 2, y: center.y - pts.height / 2,
                          width: pts.width, height: pts.height)
        rect = clampedOnScreen(rect, in: size)

        let tile = Tile(url: url, image: image, aspect: aspect, frame: rect.normalized(in: size))
        tiles.append(tile)
        selectedID = tile.id
    }

    func remove(_ id: UUID) {
        tiles.removeAll { $0.id == id }
        if selectedID == id { selectedID = tiles.last?.id }
    }

    func removeSelected() {
        if let selectedID { remove(selectedID) }
    }

    func removeAll() {
        tiles.removeAll()
        selectedID = nil
        cascadeIndex = 0
    }

    // MARK: Ordering

    func bringToFront(_ id: UUID) {
        selectedID = id
        guard let i = index(of: id), i != tiles.count - 1 else { return }
        tiles.append(tiles.remove(at: i))
    }

    func tile(_ id: UUID) -> Tile? { tiles.first { $0.id == id } }

    private func index(of id: UUID) -> Int? { tiles.firstIndex { $0.id == id } }

    // MARK: Moving, snapping, resizing (all rects in canvas points)

    /// Moves a free (unsnapped) tile to `rect`.
    func setFrame(_ id: UUID, to rect: CGRect) {
        guard let i = index(of: id) else { return }
        tiles[i].frame = rect.normalized(in: canvasSize)
        tiles[i].zone = nil
        tiles[i].restoreSize = nil
        tiles[i].preFill = nil
    }

    /// Detaches a snapped tile at the start of a drag. Returns its new frame in points,
    /// sized back to its pre-snap size and positioned so the pointer keeps its relative grip.
    func unsnap(_ id: UUID, grabbing point: CGPoint) -> CGRect? {
        guard let i = index(of: id), tiles[i].zone != nil else { return nil }
        let size = canvasSize
        let current = tiles[i].frame.denormalized(in: size)
        let restore = (tiles[i].restoreSize.map {
            CGSize(width: $0.width * size.width, height: $0.height * size.height)
        }) ?? CanvasLayout.fit(aspect: tiles[i].aspect,
                               in: CGSize(width: size.width * 0.5, height: size.height * 0.5))
        let relX = current.width > 0 ? (point.x - current.minX) / current.width : 0.5
        let relY = current.height > 0 ? (point.y - current.minY) / current.height : 0.5
        let rect = CGRect(x: point.x - restore.width * relX, y: point.y - restore.height * relY,
                          width: restore.width, height: restore.height)
        tiles[i].frame = rect.normalized(in: size)
        tiles[i].zone = nil
        tiles[i].restoreSize = nil
        tiles[i].preFill = nil
        return rect
    }

    func snap(_ id: UUID, to zone: SnapZone) {
        guard let i = index(of: id) else { return }
        if tiles[i].zone == nil { tiles[i].restoreSize = tiles[i].frame.size }
        tiles[i].frame = zone.rect
        tiles[i].zone = zone
        tiles[i].preFill = nil
    }

    /// Double-click: fill the canvas, or go back to where the tile was.
    func toggleFill(_ id: UUID) {
        guard index(of: id) != nil else { return }
        bringToFront(id)
        let j = tiles.count - 1
        if tiles[j].zone == .full {
            if let prev = tiles[j].preFill {
                tiles[j].frame = prev.frame
                tiles[j].zone = prev.zone
                if prev.zone == nil { tiles[j].restoreSize = nil }
            } else {
                tiles[j].frame = CGRect(origin: CGPoint(x: 0.25, y: 0.25),
                                        size: tiles[j].restoreSize ?? CGSize(width: 0.5, height: 0.5))
                tiles[j].zone = nil
            }
            tiles[j].preFill = nil
        } else {
            let prev = (tiles[j].frame, tiles[j].zone)
            snap(id, to: .full)
            tiles[j].preFill = prev
        }
    }

    /// Arrange > Tile All: lay every tile out in a grid, in z-order.
    func tileAll() {
        let frames = CanvasLayout.grid(count: tiles.count)
        for (i, rect) in frames.enumerated() {
            tiles[i].frame = rect
            tiles[i].zone = nil
            tiles[i].restoreSize = nil
            tiles[i].preFill = nil
        }
    }

    /// Keeps at least a grab-able strip of the tile inside the canvas.
    func clampedOnScreen(_ rect: CGRect, in size: CGSize) -> CGRect {
        let margin: CGFloat = 60
        var r = rect
        r.origin.x = min(max(r.origin.x, margin - r.width), size.width - margin)
        r.origin.y = min(max(r.origin.y, 0), size.height - margin)
        return r
    }
}
