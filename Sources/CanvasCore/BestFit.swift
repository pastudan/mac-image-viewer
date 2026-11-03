import CoreGraphics
import Foundation

/// Picks the stained-glass arrangement that leaves the least black around the pictures.
///
/// The idea: every split's divider is placed where both sides get exactly the shape of
/// what's inside them. Side by side, the widths of the two groups add up; stacked, their
/// heights do. A whole tree then has one "natural" shape, and if the canvas has that shape
/// every picture fits its pane perfectly. If not, every pane is off by the same factor, so
/// the black left over depends only on how far the tree's shape is from the canvas's.
/// The search is therefore: find the tree (and order of pictures) whose natural shape is
/// closest to the canvas, preferring trees whose panes are similar in size.
public enum BestFit {
    /// How much a lopsided layout (one tiny pane) counts against it, next to black area.
    public static let imbalanceWeight: CGFloat = 0.1
    /// A new order has to beat the current one by this much to be used, so the canvas
    /// doesn't reshuffle for no visible gain.
    public static let improvementThreshold: CGFloat = 0.003

    public struct Score: Equatable, CustomStringConvertible {
        /// Share of the canvas that's black (0...1).
        public let black: CGFloat
        /// 0 when every pane has the same area; near 1 when one pane is tiny.
        public let imbalance: CGFloat
        public var cost: CGFloat { black + BestFit.imbalanceWeight * imbalance }
        public var description: String {
            String(format: "black %.1f%%, imbalance %.2f", black * 100, imbalance)
        }
    }

    // MARK: Scoring real layouts

    /// Scores a layout by measuring its actual panes.
    public static func score<ID>(_ layout: LayoutNode<ID>, aspects: [ID: CGFloat], in size: CGSize,
                                 maxCrop: CGFloat) -> Score {
        let total = size.width * size.height
        let frames = layout.leafFrames(in: CGRect(origin: .zero, size: size))
        guard total > 0, !frames.isEmpty else { return Score(black: 0, imbalance: 0) }
        var black: CGFloat = 0
        var minArea = CGFloat.infinity
        for f in frames {
            let area = f.rect.width * f.rect.height
            minArea = min(minArea, area)
            guard f.rect.width > 0, f.rect.height > 0 else { continue }
            let coverage = FitMath.coverage(contentAspect: sanitize(aspects[f.id] ?? 1),
                                            paneAspect: f.rect.width / f.rect.height, maxCrop: maxCrop)
            black += area * (1 - coverage)
        }
        let n = CGFloat(frames.count)
        return Score(black: black / total, imbalance: max(0, 1 - n * minArea / total))
    }

    /// The same tree, with every divider moved to where both sides get their natural shape.
    public static func fittingRatios<ID>(_ layout: LayoutNode<ID>, aspects: [ID: CGFloat]) -> LayoutNode<ID> {
        func fit(_ node: LayoutNode<ID>) -> (LayoutNode<ID>, CGFloat) {
            switch node {
            case .leaf(let id):
                return (node, sanitize(aspects[id] ?? 1))
            case let .split(axis, _, a, b):
                let (na, aa) = fit(a), (nb, ab) = fit(b)
                let (aspect, ratio) = combine(axis, aa, ab)
                return (.split(axis, ratio: clampRatio(ratio), first: na, second: nb), aspect)
            }
        }
        return fit(layout).0
    }

    // MARK: Search

    /// The best layout for these pictures on a canvas of `size`. `items` is the current
    /// order; it's kept unless another order is clearly better. Never leaves more black
    /// than an even split of the same pictures.
    public static func layout<ID: Hashable>(_ items: [(id: ID, aspect: CGFloat)], in size: CGSize,
                                            maxCrop: CGFloat, timeBudget: TimeInterval = 0.03,
                                            maxEvaluations: Int = 400) -> LayoutNode<ID>? {
        guard let first = items.first else { return nil }
        if items.count == 1 { return .leaf(first.id) }
        let ids = items.map(\.id)
        let even = LayoutNode<ID>.balanced(ids, in: size)
        guard size.width > 0, size.height > 0, items.count <= 40 else { return even }

        let aspects = items.map { sanitize($0.aspect) }
        let aspectByID = Dictionary(items.map { ($0.id, sanitize($0.aspect)) }, uniquingKeysWith: { a, _ in a })
        let target = size.width / size.height
        let deadline = Date().addingTimeInterval(timeBudget)
        var evaluations = 0
        func outOfTime() -> Bool { evaluations >= maxEvaluations || Date() > deadline }

        let solver = Solver(target: target, maxCrop: maxCrop)
        func evaluate(_ order: [Int]) -> (tree: LayoutNode<Int>, cost: CGFloat)? {
            evaluations += 1
            return solver.solve(order.map { aspects[$0] }).map { tree, cost in
                (tree.compactMapIDs { order[$0] }!, cost)
            }
        }

        // Orders to try: as they are, then sorted by shape, then pairwise swaps.
        let identity = Array(items.indices)
        guard var best = evaluate(identity) else { return even }
        var bestOrder = identity
        let ascending = identity.sorted { (aspects[$0], $0) < (aspects[$1], $1) }
        var zigzag: [Int] = []
        var lo = 0, hi = ascending.count - 1
        while lo <= hi {
            zigzag.append(ascending[lo]); lo += 1
            if lo <= hi { zigzag.append(ascending[hi]); hi -= 1 }
        }
        for order in [ascending, Array(ascending.reversed()), zigzag] where !outOfTime() {
            if let candidate = evaluate(order), candidate.cost < best.cost - improvementThreshold {
                best = candidate
                bestOrder = order
            }
        }
        var improved = true
        search: while improved {
            improved = false
            for i in 0..<bestOrder.count {
                for j in (i + 1)..<bestOrder.count {
                    if outOfTime() { break search }
                    var order = bestOrder
                    order.swapAt(i, j)
                    if let candidate = evaluate(order), candidate.cost < best.cost - improvementThreshold {
                        best = candidate
                        bestOrder = order
                        improved = true
                    }
                }
            }
        }

        let fitted = best.tree.compactMapIDs { ids[$0] }!
        // Guard: measured on the real geometry, never worse than an even split.
        if let even {
            let fittedScore = score(fitted, aspects: aspectByID, in: size, maxCrop: maxCrop)
            let evenScore = score(even, aspects: aspectByID, in: size, maxCrop: maxCrop)
            if fittedScore.black > evenScore.black + 1e-9 || fittedScore.cost > evenScore.cost {
                return even
            }
        }
        return fitted
    }

    // MARK: Internals

    static func sanitize(_ aspect: CGFloat) -> CGFloat {
        guard aspect.isFinite, aspect > 0 else { return 1 }
        return min(max(aspect, 0.05), 20)
    }

    static func clampRatio(_ r: CGFloat) -> CGFloat { min(max(r, 0.01), 0.99) }

    /// Natural shape of two groups put together, and where the divider goes.
    static func combine(_ axis: Axis, _ a: CGFloat, _ b: CGFloat) -> (aspect: CGFloat, ratio: CGFloat) {
        switch axis {
        case .columns: return (a + b, a / (a + b))           // same height: widths add
        case .rows: return (a * b / (a + b), b / (a + b))     // same width: heights add
        }
    }

    /// For one order of pictures, finds the split tree whose natural shape best suits the
    /// canvas. Dynamic programming over every run of consecutive pictures: each run keeps a
    /// handful of possible trees, one per band of shapes, preferring the most even pane sizes.
    struct Solver {
        let target: CGFloat
        let maxCrop: CGFloat
        /// Width of a shape band, in natural-log units (about 16%).
        let bandWidth: Double = 0.15
        /// Shapes beyond about 1:20 either way are dropped; they can't fit any canvas well.
        let logLimit: Double = 3.0

        struct Entry {
            var aspect: Double
            /// Smallest pane's share of this group's area, with natural dividers.
            var minShare: Double
            var axis: Axis = .columns
            var ratio: Double = 1
            var split = -1, left = -1, right = -1
        }

        func solve(_ aspects: [CGFloat]) -> (LayoutNode<Int>, CGFloat)? {
            let n = aspects.count
            guard n > 0 else { return nil }
            var table = [[Entry]](repeating: [], count: n * n)
            func at(_ i: Int, _ j: Int) -> Int { i * n + j }
            for i in 0..<n {
                table[at(i, i)] = [Entry(aspect: Double(aspects[i]), minShare: 1)]
            }
            if n > 1 {
                for length in 2...n {
                    for i in 0...(n - length) {
                        let j = i + length - 1
                        var bands: [Int: Entry] = [:]
                        for k in i..<j {
                            let lhs = table[at(i, k)], rhs = table[at(k + 1, j)]
                            for (li, l) in lhs.enumerated() {
                                for (ri, r) in rhs.enumerated() {
                                    for axis in [Axis.columns, .rows] {
                                        let sum = l.aspect + r.aspect
                                        let aspect = axis == .columns ? sum : l.aspect * r.aspect / sum
                                        let ratio = axis == .columns ? l.aspect / sum : r.aspect / sum
                                        let logAspect = log(aspect)
                                        guard abs(logAspect) <= logLimit else { continue }
                                        let share = min(ratio * l.minShare, (1 - ratio) * r.minShare)
                                        let band = Int((logAspect / bandWidth).rounded(.down))
                                        if let existing = bands[band], existing.minShare >= share { continue }
                                        bands[band] = Entry(aspect: aspect, minShare: share, axis: axis,
                                                            ratio: ratio, split: k, left: li, right: ri)
                                    }
                                }
                            }
                        }
                        table[at(i, j)] = bands.keys.sorted().map { bands[$0]! }
                    }
                }
            }

            // Pick the whole-run tree that suits the canvas best.
            var bestIndex = -1
            var bestCost = CGFloat.infinity
            for (index, entry) in table[at(0, n - 1)].enumerated() {
                let m = FitMath.mismatch(CGFloat(entry.aspect), target)
                let black = 1 - FitMath.coverage(mismatch: m, maxCrop: maxCrop)
                let imbalance = max(0, 1 - CGFloat(n) * CGFloat(entry.minShare))
                let cost = black + BestFit.imbalanceWeight * imbalance
                if cost < bestCost {
                    bestCost = cost
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { return nil }

            func build(_ i: Int, _ j: Int, _ index: Int) -> LayoutNode<Int> {
                let e = table[at(i, j)][index]
                if i == j { return .leaf(i) }
                return .split(e.axis, ratio: BestFit.clampRatio(CGFloat(e.ratio)),
                              first: build(i, e.split, e.left),
                              second: build(e.split + 1, j, e.right))
            }
            return (build(0, n - 1, bestIndex), bestCost)
        }
    }
}
