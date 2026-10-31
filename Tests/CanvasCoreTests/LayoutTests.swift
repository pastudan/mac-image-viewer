import CanvasCore
import CoreGraphics
import XCTest

final class LayoutTests: XCTestCase {
    typealias L = LayoutNode<String>
    let size = CGSize(width: 1200, height: 800)
    var canvas: CGRect { CGRect(origin: .zero, size: size) }

    /// Tiles must cover the canvas exactly: total area matches and no two overlap.
    func assertStainedGlass(_ layout: L?, file: StaticString = #filePath, line: UInt = #line) {
        guard let layout else { return XCTFail("nil layout", file: file, line: line) }
        let frames = layout.leafFrames(in: canvas)
        let area = frames.map { $0.rect.width * $0.rect.height }.reduce(0, +)
        XCTAssertEqual(area, size.width * size.height, accuracy: 0.01, file: file, line: line)
        for i in frames.indices {
            XCTAssertTrue(canvas.insetBy(dx: -0.01, dy: -0.01).contains(frames[i].rect), file: file, line: line)
            for j in frames.indices where j > i {
                let overlap = frames[i].rect.intersection(frames[j].rect)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01,
                              "\(frames[i].id) overlaps \(frames[j].id)", file: file, line: line)
            }
        }
        XCTAssertEqual(Set(layout.ids).count, layout.ids.count, "duplicate ids", file: file, line: line)
    }

    func build(_ ids: [String]) -> L {
        var l: L?
        for id in ids { l = L.adding(id, to: l, in: size) }
        return l!
    }

    func testAddingSplitsLargestAlongLongerSide() {
        let one = L.adding("a", to: nil, in: size)
        XCTAssertEqual(one, .leaf("a"))
        let two = L.adding("b", to: one, in: size)
        // Canvas is wider than tall, so b goes to the right.
        XCTAssertEqual(two.frames(in: canvas)["b"], CGRect(x: 600, y: 0, width: 600, height: 800))
        let three = L.adding("c", to: two, in: size)
        // a (600x800) is the first largest and taller than wide: c goes beneath it.
        XCTAssertEqual(three.frames(in: canvas)["c"], CGRect(x: 0, y: 400, width: 600, height: 400))
        XCTAssertEqual(three.frames(in: canvas)["b"], CGRect(x: 600, y: 0, width: 600, height: 800))
        assertStainedGlass(three)
    }

    func testManyAddsStayGapless() {
        assertStainedGlass(build((0..<13).map(String.init)))
    }

    func testRemovingLetsSiblingExpand() {
        let l = build(["a", "b", "c"])
        let without = l.removing("c")
        XCTAssertEqual(without?.frames(in: canvas)["a"], CGRect(x: 0, y: 0, width: 600, height: 800))
        assertStainedGlass(without)
        XCTAssertNil(L.leaf("a").removing("a"))
    }

    func testSnapToEdgeTakesFullHalf() {
        let l = build(["a", "b", "c", "d"])
        let snapped = L.snapping("d", to: .leftHalf, in: l)
        XCTAssertEqual(snapped.frames(in: canvas)["d"], CGRect(x: 0, y: 0, width: 600, height: 800))
        assertStainedGlass(snapped)
        let top = L.snapping("a", to: .topHalf, in: l)
        XCTAssertEqual(top.frames(in: canvas)["a"], CGRect(x: 0, y: 0, width: 1200, height: 400))
        assertStainedGlass(top)
    }

    func testSnapToCornerGivesQuadrantWhenHalvesExist() {
        // a | b, then drop c in the top-right corner: c over b.
        let l = build(["a", "b"])
        let snapped = L.snapping("c", to: .topRight, in: l)
        XCTAssertEqual(snapped.frames(in: canvas)["c"], CGRect(x: 600, y: 0, width: 600, height: 400))
        XCTAssertEqual(snapped.frames(in: canvas)["b"], CGRect(x: 600, y: 400, width: 600, height: 400))
        assertStainedGlass(snapped)
        // Four quadrants.
        let four = L.snapping("d", to: .bottomLeft, in: snapped)
        XCTAssertEqual(four.frames(in: canvas)["d"], CGRect(x: 0, y: 400, width: 600, height: 400))
        assertStainedGlass(four)
    }

    func testCornerWithOneOtherTileFallsBackToHalf() {
        let l = build(["a", "b"])
        let snapped = L.snapping("b", to: .bottomLeft, in: l)
        XCTAssertEqual(snapped.frames(in: canvas)["b"], CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    func testInsertBesideSplitsTarget() {
        let l = build(["a", "b", "c"])
        let moved = l.inserting("a", beside: "b", on: .top)
        let f = moved.frames(in: canvas)
        XCTAssertEqual(f["a"], CGRect(x: 600, y: 0, width: 600, height: 400))
        XCTAssertEqual(f["b"], CGRect(x: 600, y: 400, width: 600, height: 400))
        XCTAssertEqual(f["c"], CGRect(x: 0, y: 0, width: 600, height: 800)) // c grew into a's space
        assertStainedGlass(moved)
        XCTAssertEqual(l.inserting("a", beside: "a", on: .left), l)
    }

    func testSwapKeepsGeometry() {
        let l = build(["a", "b", "c"])
        let s = l.swapping("a", "b")
        XCTAssertEqual(s.frames(in: canvas)["b"], l.frames(in: canvas)["a"])
        XCTAssertEqual(s.frames(in: canvas)["a"], l.frames(in: canvas)["b"])
    }

    func testDropTargets() {
        let l = build(["a", "b"]) // a: left half, b: right half
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: 3, y: 400), in: size, moving: "b"), .snap(.leftHalf))
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: 300, y: 400), in: size, moving: "b"), .swap("a"))
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: 300, y: 100), in: size, moving: "b"), .beside("a", .top))
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: 560, y: 400), in: size, moving: "b"), .beside("a", .right))
        XCTAssertNil(l.dropTarget(at: CGPoint(x: 900, y: 400), in: size, moving: "b"))
    }

    func testDroppingNewFileInCentreSplitsTile() {
        let l = build(["a"])
        let result = l.applying(.swap("a"), moving: "new", in: size)
        XCTAssertEqual(result.frames(in: canvas)["new"], CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    func testBalancedGivesEqualAreas() {
        for n in 1...9 {
            let ids = (0..<n).map(String.init)
            let l = L.balanced(ids, in: size)
            assertStainedGlass(l)
            let areas = l!.leafFrames(in: canvas).map { $0.rect.width * $0.rect.height }
            for a in areas { XCTAssertEqual(a, size.width * size.height / CGFloat(n), accuracy: 0.01) }
        }
        XCTAssertNil(L.balanced([], in: size))
    }

    func testDividerRatio() {
        let l = build(["a", "b"])
        let d = l.dividers(in: canvas)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].position, 600)
        let resized = l.settingRatio(0.25, at: d[0].path)
        XCTAssertEqual(resized.frames(in: canvas)["a"]?.width, 300)
        XCTAssertEqual(l.settingRatio(0, at: []).frames(in: canvas)["a"]!.width, 60, accuracy: 0.001)
    }
}
