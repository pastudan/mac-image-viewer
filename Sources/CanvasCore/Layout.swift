import CoreGraphics

/// How a split divides its space. `columns` puts children side by side (left | right);
/// `rows` stacks them (top / bottom).
public enum Axis: Sendable, Equatable {
    case columns, rows
}

public enum Side: Sendable, CaseIterable, Equatable {
    case left, right, top, bottom

    public var axis: Axis { self == .left || self == .right ? .columns : .rows }
    /// Left and top come first in a split.
    public var isLeading: Bool { self == .left || self == .top }
}

/// Where a dragged tile will land.
public enum DropTarget<ID: Hashable>: Equatable {
    /// Canvas edge or corner, Windows-Snap style.
    case snap(SnapZone)
    /// Split another tile and take the given side of it.
    case beside(ID, Side)
    /// Trade places with another tile.
    case swap(ID)
}

/// A stained-glass layout: a binary space partition where every leaf is a tile, and the
/// tiles always cover the whole canvas with no gaps or overlaps. Adding or moving a tile
/// splits a neighbour, so the others shrink to make room.
public indirect enum LayoutNode<ID: Hashable>: Equatable {
    case leaf(ID)
    case split(Axis, ratio: CGFloat, first: LayoutNode, second: LayoutNode)

    // MARK: Reading

    /// Tile ids in reading order (left-to-right, top-to-bottom through the tree).
    public var ids: [ID] {
        switch self {
        case .leaf(let id): [id]
        case let .split(_, _, a, b): a.ids + b.ids
        }
    }

    public func contains(_ id: ID) -> Bool {
        switch self {
        case .leaf(let x): x == id
        case let .split(_, _, a, b): a.contains(id) || b.contains(id)
        }
    }

    /// Every tile's rect within `rect`, in reading order.
    public func leafFrames(in rect: CGRect) -> [(id: ID, rect: CGRect)] {
        switch self {
        case .leaf(let id):
            return [(id, rect)]
        case let .split(axis, ratio, a, b):
            let (ra, rb) = Self.divide(rect, axis, ratio)
            return a.leafFrames(in: ra) + b.leafFrames(in: rb)
        }
    }

    public func frames(in rect: CGRect) -> [ID: CGRect] {
        Dictionary(leafFrames(in: rect).map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
    }

    public static func divide(_ rect: CGRect, _ axis: Axis, _ ratio: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .columns:
            let w = rect.width * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
        case .rows:
            let h = rect.height * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h),
                    CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
        }
    }

    // MARK: Editing

    /// The layout without `id`. Its sibling expands to fill the freed space.
    public func removing(_ id: ID) -> LayoutNode? {
        switch self {
        case .leaf(let x):
            return x == id ? nil : self
        case let .split(axis, ratio, a, b):
            switch (a.removing(id), b.removing(id)) {
            case (nil, nil): return nil
            case (let n?, nil), (nil, let n?): return n
            case let (x?, y?): return .split(axis, ratio: ratio, first: x, second: y)
            }
        }
    }

    /// `node` split in half with `id` taking `side`.
    public static func pair(_ id: ID, beside node: LayoutNode, on side: Side) -> LayoutNode {
        side.isLeading
            ? .split(side.axis, ratio: 0.5, first: .leaf(id), second: node)
            : .split(side.axis, ratio: 0.5, first: node, second: .leaf(id))
    }

    func replacingLeaf(_ target: ID, with node: LayoutNode) -> LayoutNode {
        switch self {
        case .leaf(let x):
            return x == target ? node : self
        case let .split(axis, ratio, a, b):
            return .split(axis, ratio: ratio,
                          first: a.replacingLeaf(target, with: node),
                          second: b.replacingLeaf(target, with: node))
        }
    }

    /// Moves (or inserts) `id` so it takes `side` of `target`, halving `target`.
    public func inserting(_ id: ID, beside target: ID, on side: Side) -> LayoutNode {
        guard id != target else { return self }
        guard let rest = removing(id) else { return .leaf(id) }
        guard rest.contains(target) else { return Self.pair(id, beside: rest, on: side) }
        return rest.replacingLeaf(target, with: Self.pair(id, beside: .leaf(target), on: side))
    }

    public func swapping(_ a: ID, _ b: ID) -> LayoutNode {
        switch self {
        case .leaf(let x):
            return x == a ? .leaf(b) : x == b ? .leaf(a) : self
        case let .split(axis, ratio, f, s):
            return .split(axis, ratio: ratio, first: f.swapping(a, b), second: s.swapping(a, b))
        }
    }

    /// Sets the ratio of the split at `path` (false = first child, true = second).
    public func settingRatio(_ newRatio: CGFloat, at path: [Bool]) -> LayoutNode {
        guard case let .split(axis, ratio, a, b) = self else { return self }
        guard let step = path.first else {
            return .split(axis, ratio: min(max(newRatio, 0.05), 0.95), first: a, second: b)
        }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis, ratio: ratio, first: a, second: b.settingRatio(newRatio, at: rest))
            : .split(axis, ratio: ratio, first: a.settingRatio(newRatio, at: rest), second: b)
    }

    // MARK: Whole-layout operations

    /// Adds `id` by halving the largest tile along its longer side.
    public static func adding(_ id: ID, to root: LayoutNode?, in size: CGSize) -> LayoutNode {
        guard let rest = root?.removing(id) else { return .leaf(id) }
        let frames = rest.leafFrames(in: CGRect(origin: .zero, size: size))
        guard let largest = frames.max(by: { $0.rect.area < $1.rect.area }) else { return .leaf(id) }
        let side: Side = largest.rect.width >= largest.rect.height ? .right : .bottom
        return rest.replacingLeaf(largest.id, with: pair(id, beside: .leaf(largest.id), on: side))
    }

    /// Moves `id` to a canvas edge (taking a full half) or corner (a quarter).
    public static func snapping(_ id: ID, to zone: SnapZone, in root: LayoutNode?) -> LayoutNode {
        guard let rest = root?.removing(id) else { return .leaf(id) }
        switch zone {
        case .leftHalf: return pair(id, beside: rest, on: .left)
        case .rightHalf: return pair(id, beside: rest, on: .right)
        case .topHalf: return pair(id, beside: rest, on: .top)
        case .bottomHalf: return pair(id, beside: rest, on: .bottom)
        case .full: return root ?? .leaf(id)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let h: Side = (zone == .topLeft || zone == .bottomLeft) ? .left : .right
            let v: Side = (zone == .topLeft || zone == .topRight) ? .top : .bottom
            switch rest {
            case let .split(.columns, ratio, a, b):
                // Already left | right: stack into the matching column.
                return h == .left
                    ? .split(.columns, ratio: ratio, first: pair(id, beside: a, on: v), second: b)
                    : .split(.columns, ratio: ratio, first: a, second: pair(id, beside: b, on: v))
            case let .split(.rows, ratio, a, b):
                // Already top / bottom: sit beside the matching row.
                return v == .top
                    ? .split(.rows, ratio: ratio, first: pair(id, beside: a, on: h), second: b)
                    : .split(.rows, ratio: ratio, first: a, second: pair(id, beside: b, on: h))
            case .leaf:
                // Two tiles can't make a quarter without a gap; take the half instead.
                return pair(id, beside: rest, on: h)
            }
        }
    }

    /// An even layout: every tile gets the same area, splitting along the longer side.
    public static func balanced(_ ids: [ID], in size: CGSize) -> LayoutNode? {
        func build(_ slice: ArraySlice<ID>, _ rect: CGRect) -> LayoutNode? {
            guard let first = slice.first else { return nil }
            if slice.count == 1 { return .leaf(first) }
            let axis: Axis = rect.width >= rect.height ? .columns : .rows
            let half = slice.count / 2
            let ratio = CGFloat(half) / CGFloat(slice.count)
            let (ra, rb) = divide(rect, axis, ratio)
            let mid = slice.startIndex + half
            guard let a = build(slice[slice.startIndex..<mid], ra),
                  let b = build(slice[mid...], rb) else { return nil }
            return .split(axis, ratio: ratio, first: a, second: b)
        }
        return build(ids[...], CGRect(origin: .zero, size: size))
    }

    // MARK: Dragging

    /// What dropping at `point` would do. `moving` is the dragged tile, or nil for a new file.
    public func dropTarget(at point: CGPoint, in size: CGSize, moving id: ID?) -> DropTarget<ID>? {
        if let zone = SnapZone.zone(for: point, in: size) { return .snap(zone) }
        let frames = leafFrames(in: CGRect(origin: .zero, size: size))
        guard let hit = frames.first(where: { $0.rect.contains(point) }),
              hit.id != id, hit.rect.width > 0, hit.rect.height > 0 else { return nil }
        let u = (point.x - hit.rect.minX) / hit.rect.width
        let v = (point.y - hit.rect.minY) / hit.rect.height
        if (0.3...0.7).contains(u), (0.3...0.7).contains(v) { return .swap(hit.id) }
        let distances: [(Side, CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        let side = distances.min(by: { $0.1 < $1.1 })!.0
        return .beside(hit.id, side)
    }

    /// The layout after dropping `id` on `target`.
    public func applying(_ target: DropTarget<ID>, moving id: ID, in size: CGSize) -> LayoutNode {
        switch target {
        case .snap(let zone):
            return Self.snapping(id, to: zone, in: self)
        case let .beside(other, side):
            return inserting(id, beside: other, on: side)
        case .swap(let other):
            if contains(id) { return swapping(id, other) }
            // A new file dropped in a tile's centre: split it along its longer side.
            let rect = frames(in: CGRect(origin: .zero, size: size))[other] ?? .zero
            return inserting(id, beside: other, on: rect.width >= rect.height ? .right : .bottom)
        }
    }

    // MARK: Dividers

    public struct Divider: Equatable {
        /// Path to the split node (false = first child, true = second).
        public let path: [Bool]
        public let axis: Axis
        /// The rect the split divides.
        public let container: CGRect
        /// The divider's position: an x for columns, a y for rows.
        public let position: CGFloat
    }

    public func dividers(in rect: CGRect, path: [Bool] = []) -> [Divider] {
        guard case let .split(axis, ratio, a, b) = self else { return [] }
        let (ra, rb) = Self.divide(rect, axis, ratio)
        let position = axis == .columns ? ra.maxX : ra.maxY
        return [Divider(path: path, axis: axis, container: rect, position: position)]
            + a.dividers(in: ra, path: path + [false])
            + b.dividers(in: rb, path: path + [true])
    }
}

extension CGRect {
    var area: CGFloat { width * height }
}
