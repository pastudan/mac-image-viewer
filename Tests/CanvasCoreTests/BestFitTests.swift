import CanvasCore
import CoreGraphics
import Foundation
import XCTest

final class BestFitTests: XCTestCase {
    typealias L = LayoutNode<String>

    // MARK: Fit maths

    func testCoverage() {
        XCTAssertEqual(FitMath.coverage(contentAspect: 1, paneAspect: 1, maxCrop: 0), 1)
        XCTAssertEqual(FitMath.coverage(contentAspect: 0.5, paneAspect: 1, maxCrop: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FitMath.coverage(contentAspect: 0.5, paneAspect: 1, maxCrop: 0.1), 0.5 / 0.9, accuracy: 1e-9)
        XCTAssertEqual(FitMath.coverage(contentAspect: 0.5, paneAspect: 1, maxCrop: 1), 1)
        // A 10% allowance absorbs a 10% mismatch completely.
        XCTAssertEqual(FitMath.coverage(contentAspect: 1.1, paneAspect: 1, maxCrop: 0.1), 1, accuracy: 1e-9)
    }

    func testDisplaySize() {
        let pane = CGSize(width: 100, height: 100)
        XCTAssertEqual(FitMath.displaySize(contentAspect: 2, in: pane, maxCrop: 0), CGSize(width: 100, height: 50))
        let crop10 = FitMath.displaySize(contentAspect: 2, in: pane, maxCrop: 0.1)
        XCTAssertEqual(crop10.width, 100 / 0.9, accuracy: 1e-6)
        XCTAssertEqual(crop10.height, 50 / 0.9, accuracy: 1e-6)
        XCTAssertEqual(FitMath.trimmed(contentAspect: 2, in: pane, maxCrop: 0.1), 0.1, accuracy: 1e-6)
        XCTAssertEqual(FitMath.displaySize(contentAspect: 2, in: pane, maxCrop: 1), CGSize(width: 200, height: 100))
        // Small mismatch: grows only until it fills, trimming less than the allowance.
        let near = FitMath.displaySize(contentAspect: 1.05, in: pane, maxCrop: 0.1)
        XCTAssertEqual(near.height, 100, accuracy: 1e-6)
        XCTAssertLessThan(FitMath.trimmed(contentAspect: 1.05, in: pane, maxCrop: 0.1), 0.1)
    }

    func testFittingRatiosGivesNaturalDividers() {
        let tree = L.split(.columns, ratio: 0.5, first: .leaf("a"), second: .leaf("b"))
        let fitted = BestFit.fittingRatios(tree, aspects: ["a": 1, "b": 3])
        guard case let .split(_, ratio, _, _) = fitted else { return XCTFail() }
        XCTAssertEqual(ratio, 0.25, accuracy: 1e-9)
        let rows = L.split(.rows, ratio: 0.5, first: .leaf("a"), second: .leaf("b"))
        guard case let .split(_, rowRatio, _, _) = BestFit.fittingRatios(rows, aspects: ["a": 1, "b": 3]) else { return XCTFail() }
        XCTAssertEqual(rowRatio, 0.75, accuracy: 1e-9) // a is taller relative to width, so it gets more height
    }

    // MARK: Search

    func testFourTallPicturesGoSideBySideOnAWideCanvas() throws {
        // Four 1:2 portraits on a 2:1 canvas fit perfectly as four columns.
        let size = CGSize(width: 1200, height: 600)
        let items = ["a", "b", "c", "d"].map { (id: $0, aspect: CGFloat(0.5)) }
        let layout = try XCTUnwrap(BestFit.layout(items, in: size, maxCrop: 0.1))
        let aspects = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.aspect) })
        XCTAssertLessThan(BestFit.score(layout, aspects: aspects, in: size, maxCrop: 0.1).black, 0.01)
        for f in layout.leafFrames(in: CGRect(origin: .zero, size: size)) {
            XCTAssertEqual(f.rect.width, 300, accuracy: 0.5)
            XCTAssertEqual(f.rect.height, 600, accuracy: 0.5)
        }
    }

    func testMixedPhotosBeatEvenSplitClearly() throws {
        // Two landscape 16:9 and two portrait 9:16 photos in a 16:9 window. An even split
        // gives every photo a landscape pane, so the portraits drown in black.
        let size = CGSize(width: 1600, height: 900)
        let items: [(id: String, aspect: CGFloat)] = [("w1", 16 / 9), ("t1", 9 / 16), ("w2", 16 / 9), ("t2", 9 / 16)]
        let layout = try XCTUnwrap(BestFit.layout(items, in: size, maxCrop: 0.1))
        let aspects = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.aspect) })
        let best = BestFit.score(layout, aspects: aspects, in: size, maxCrop: 0.1)
        let even = BestFit.score(L.balanced(items.map(\.id), in: size)!, aspects: aspects, in: size, maxCrop: 0.1)
        XCTAssertGreaterThan(even.black, 0.25, "\(even)")
        XCTAssertLessThan(best.black, even.black - 0.15, "best \(best) vs even \(even)")
        assertGapless(layout, size: size, count: 4)
    }

    func testOneWideTwoTallOnSquareCanvas() throws {
        let size = CGSize(width: 1000, height: 1000)
        let items: [(id: String, aspect: CGFloat)] = [("wide", 2), ("t1", 0.5), ("t2", 0.5)]
        let layout = try XCTUnwrap(BestFit.layout(items, in: size, maxCrop: 0.1))
        let aspects = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.aspect) })
        let best = BestFit.score(layout, aspects: aspects, in: size, maxCrop: 0.1)
        let even = BestFit.score(L.balanced(items.map(\.id), in: size)!, aspects: aspects, in: size, maxCrop: 0.1)
        XCTAssertLessThan(best.black, 0.05, "\(best)")
        XCTAssertLessThan(best.black, even.black)
        assertGapless(layout, size: size, count: 3)
    }

    func testNeverWorseThanEvenAndAlwaysGapless() throws {
        var rng = LCG(seed: 42)
        for trial in 0..<40 {
            let n = 1 + trial % 9
            let size = CGSize(width: 600 + rng.next() * 1400, height: 400 + rng.next() * 900)
            let items = (0..<n).map { (id: "p\($0)", aspect: CGFloat(0.4 + rng.next() * 2.4)) }
            let aspects = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.aspect) })
            let layout = try XCTUnwrap(BestFit.layout(items, in: size, maxCrop: 0.1, timeBudget: 1))
            assertGapless(layout, size: size, count: n)
            let best = BestFit.score(layout, aspects: aspects, in: size, maxCrop: 0.1)
            let even = BestFit.score(L.balanced(items.map(\.id), in: size)!, aspects: aspects, in: size, maxCrop: 0.1)
            XCTAssertLessThanOrEqual(best.black, even.black + 1e-9, "trial \(trial): \(best) vs even \(even)")
        }
    }

    func testDeterministic() {
        var rng = LCG(seed: 7)
        let items = (0..<9).map { (id: "p\($0)", aspect: CGFloat(0.4 + rng.next() * 2)) }
        let size = CGSize(width: 1440, height: 900)
        let a = BestFit.layout(items, in: size, maxCrop: 0.1, timeBudget: 60, maxEvaluations: 120)
        let b = BestFit.layout(items, in: size, maxCrop: 0.1, timeBudget: 60, maxEvaluations: 120)
        XCTAssertEqual(a, b)
    }

    func testSixteenPicturesFinishQuickly() throws {
        var rng = LCG(seed: 3)
        let items = (0..<16).map { (id: "p\($0)", aspect: CGFloat(0.5 + rng.next() * 1.5)) }
        let size = CGSize(width: 1440, height: 900)
        let start = Date()
        let layout = try XCTUnwrap(BestFit.layout(items, in: size, maxCrop: 0.1))
        let elapsed = Date().timeIntervalSince(start)
        // Debug builds are much slower than the release app; this just catches blow-ups.
        XCTAssertLessThan(elapsed, 3, "took \(elapsed)s")
        assertGapless(layout, size: size, count: 16)
    }

    func testSingleAndEmpty() {
        XCTAssertNil(BestFit.layout([(id: String, aspect: CGFloat)](), in: CGSize(width: 10, height: 10), maxCrop: 0.1))
        XCTAssertEqual(BestFit.layout([(id: "a", aspect: 3)], in: CGSize(width: 10, height: 10), maxCrop: 0.1), .leaf("a"))
    }

    func testKeepsOrderWhenNothingToGain() throws {
        // Four identical squares: any order is equally good, so the given order is kept.
        let items = ["a", "b", "c", "d"].map { (id: $0, aspect: CGFloat(1)) }
        let layout = try XCTUnwrap(BestFit.layout(items, in: CGSize(width: 1000, height: 1000), maxCrop: 0.1))
        XCTAssertEqual(layout.ids, ["a", "b", "c", "d"])
    }

    // MARK: Helpers

    func assertGapless(_ layout: L, size: CGSize, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let frames = layout.leafFrames(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(frames.count, count, file: file, line: line)
        XCTAssertEqual(Set(frames.map(\.id)).count, count, file: file, line: line)
        let area = frames.map { $0.rect.width * $0.rect.height }.reduce(0, +)
        XCTAssertEqual(area, size.width * size.height, accuracy: 0.5, file: file, line: line)
    }
}

/// Small deterministic random numbers for tests.
struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
}
