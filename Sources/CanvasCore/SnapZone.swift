import CoreGraphics

/// A region of the canvas a tile can snap to. Rects are normalized (0...1) in a
/// top-left-origin space, so they scale with the window.
public enum SnapZone: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    /// Fills the whole canvas. Only reachable via double-click, never by dragging.
    case full

    public var rect: CGRect {
        switch self {
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .full: CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// The zone the pointer is hovering, Windows-Snap style.
    ///
    /// - Parameters:
    ///   - point: pointer location in canvas points (top-left origin). May lie outside the canvas.
    ///   - size: canvas size in points.
    ///   - edge: how close to an edge the pointer must be to trigger a half.
    ///   - corner: how far along an edge from a corner still counts as that corner (quadrant).
    public static func zone(
        for point: CGPoint,
        in size: CGSize,
        edge: CGFloat = 24,
        corner: CGFloat = 80
    ) -> SnapZone? {
        guard size.width > 0, size.height > 0 else { return nil }
        let nearLeft = point.x <= edge
        let nearRight = point.x >= size.width - edge
        let nearTop = point.y <= edge
        let nearBottom = point.y >= size.height - edge

        // Keep the corner reach sane on tiny canvases.
        let cx = min(corner, size.width / 2)
        let cy = min(corner, size.height / 2)
        let inTopBand = point.y <= cy
        let inBottomBand = point.y >= size.height - cy
        let inLeftBand = point.x <= cx
        let inRightBand = point.x >= size.width - cx

        if nearLeft || nearRight {
            let left = nearLeft
            if inTopBand { return left ? .topLeft : .topRight }
            if inBottomBand { return left ? .bottomLeft : .bottomRight }
            return left ? .leftHalf : .rightHalf
        }
        if nearTop || nearBottom {
            let top = nearTop
            if inLeftBand { return top ? .topLeft : .bottomLeft }
            if inRightBand { return top ? .topRight : .bottomRight }
            return top ? .topHalf : .bottomHalf
        }
        return nil
    }
}

public enum CanvasLayout {
    /// Normalized frames for `count` tiles in a near-square grid, filled row by row.
    public static func grid(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(cols)).rounded(.up))
        let w = 1 / CGFloat(cols)
        let h = 1 / CGFloat(rows)
        return (0..<count).map { i in
            CGRect(x: CGFloat(i % cols) * w, y: CGFloat(i / cols) * h, width: w, height: h)
        }
    }

    /// Size (in points) of an image with `aspect` (w/h) fitted inside `bounds`.
    public static func fit(aspect: CGFloat, in bounds: CGSize) -> CGSize {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        if bounds.width / bounds.height > aspect {
            return CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGSize(width: bounds.width, height: bounds.width / aspect)
    }
}

public extension CGRect {
    /// Converts a normalized rect to points within `size`.
    func denormalized(in size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height,
               width: width * size.width, height: height * size.height)
    }

    /// Converts a rect in points to normalized coordinates within `size`.
    func normalized(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return self }
        return CGRect(x: minX / size.width, y: minY / size.height,
                      width: width / size.width, height: height / size.height)
    }
}
