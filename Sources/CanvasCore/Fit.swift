import CoreGraphics

/// How a picture is drawn inside a pane: shrunk to fit, then allowed to grow until up to
/// `maxCrop` of it is trimmed off the overflowing edges (split evenly between both sides),
/// but never beyond filling the pane. `maxCrop` 0 is plain "fit"; 1 or more is "fill".
/// The same maths gives each pane's coverage, so drawing and layout scoring always agree.
public enum FitMath {
    public static let defaultMaxCrop: CGFloat = 0.10

    /// How far apart two shapes are: 1 when equal, 2 when one is twice as wide (or tall).
    public static func mismatch(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard a > 0, b > 0, a.isFinite, b.isFinite else { return 1 }
        return max(a, b) / min(a, b)
    }

    /// The share of a pane (0...1) that a picture covers.
    public static func coverage(contentAspect a: CGFloat, paneAspect r: CGFloat, maxCrop c: CGFloat) -> CGFloat {
        coverage(mismatch: mismatch(a, r), maxCrop: c)
    }

    public static func coverage(mismatch m: CGFloat, maxCrop c: CGFloat) -> CGFloat {
        if c >= 1 { return 1 }
        return min(1, 1 / (max(m, 1) * (1 - max(c, 0))))
    }

    /// The size to draw a picture of aspect `a` (width / height) in `pane`, centred and clipped.
    public static func displaySize(contentAspect a: CGFloat, in pane: CGSize, maxCrop c: CGFloat) -> CGSize {
        guard a > 0, a.isFinite, pane.width > 0, pane.height > 0 else { return pane }
        let r = pane.width / pane.height
        let fit = a >= r
            ? CGSize(width: pane.width, height: pane.width / a)
            : CGSize(width: pane.height * a, height: pane.height)
        let m = mismatch(a, r)
        let grow = c >= 1 ? m : min(m, 1 / (1 - max(c, 0)))
        return CGSize(width: fit.width * grow, height: fit.height * grow)
    }

    /// Fraction of the picture's width or height that ends up trimmed (0 when it fits).
    public static func trimmed(contentAspect a: CGFloat, in pane: CGSize, maxCrop c: CGFloat) -> CGFloat {
        let shown = displaySize(contentAspect: a, in: pane, maxCrop: c)
        guard shown.width > 0, shown.height > 0 else { return 0 }
        return max(0, 1 - min(pane.width / shown.width, pane.height / shown.height))
    }
}
