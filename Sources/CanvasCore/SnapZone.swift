import CoreGraphics

/// A canvas edge or corner a tile can be dropped on. Edges give a full half of the
/// canvas, corners a quarter. `full` is the double-click zoom, never a drag target.
public enum SnapZone: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case full

    /// The zone the pointer is hovering, Windows-Snap style.
    ///
    /// - Parameters:
    ///   - point: pointer location in canvas points (top-left origin). May lie outside the canvas.
    ///   - size: canvas size in points.
    ///   - edge: how close to an edge the pointer must be to trigger a half.
    ///   - corner: how far along an edge from a corner still counts as that corner.
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
