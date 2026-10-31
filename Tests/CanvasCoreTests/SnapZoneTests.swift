import CanvasCore
import CoreGraphics
import XCTest

final class SnapZoneTests: XCTestCase {
    let size = CGSize(width: 1000, height: 600)

    func testInteriorIsNoZone() {
        XCTAssertNil(SnapZone.zone(for: CGPoint(x: 500, y: 300), in: size))
        XCTAssertNil(SnapZone.zone(for: CGPoint(x: 30, y: 300), in: size))
    }

    func testEdgesGiveHalves() {
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 300), in: size), .leftHalf)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 995, y: 300), in: size), .rightHalf)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 500, y: 2), in: size), .topHalf)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 500, y: 598), in: size), .bottomHalf)
    }

    func testPointerPastEdgeStillSnaps() {
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: -40, y: 300), in: size), .leftHalf)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 1100, y: 300), in: size), .rightHalf)
    }

    func testCornersGiveQuadrants() {
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 5), in: size), .topLeft)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 995, y: 5), in: size), .topRight)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 595), in: size), .bottomLeft)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 995, y: 595), in: size), .bottomRight)
    }

    func testCornerReachAlongEdges() {
        // On the left edge, 60pt from the top is still the top-left corner (reach 80).
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 60), in: size), .topLeft)
        // On the top edge, 70pt from the right is the top-right corner.
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 930, y: 5), in: size), .topRight)
        // Further along it's a half.
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 120), in: size), .leftHalf)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 850, y: 5), in: size), .topHalf)
    }

    func testZoneRectsTileTheCanvas() {
        let quads: [SnapZone] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let area = quads.map { $0.rect.width * $0.rect.height }.reduce(0, +)
        XCTAssertEqual(area, 1, accuracy: 1e-9)
        XCTAssertEqual(SnapZone.leftHalf.rect.union(SnapZone.rightHalf.rect), SnapZone.full.rect)
        XCTAssertEqual(SnapZone.topHalf.rect.union(SnapZone.bottomHalf.rect), SnapZone.full.rect)
    }

    func testDegenerateCanvas() {
        XCTAssertNil(SnapZone.zone(for: .zero, in: .zero))
    }

    func testNormalizeRoundTrip() {
        let r = CGRect(x: 100, y: 60, width: 250, height: 300)
        XCTAssertEqual(r.normalized(in: size).denormalized(in: size), r)
        XCTAssertEqual(SnapZone.rightHalf.rect.denormalized(in: size),
                       CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    func testGrid() {
        XCTAssertEqual(CanvasLayout.grid(count: 0), [])
        XCTAssertEqual(CanvasLayout.grid(count: 1), [CGRect(x: 0, y: 0, width: 1, height: 1)])
        XCTAssertEqual(CanvasLayout.grid(count: 2).map(\.width), [0.5, 0.5])
        XCTAssertEqual(CanvasLayout.grid(count: 2).map(\.height), [1, 1])
        let five = CanvasLayout.grid(count: 5) // 3 cols x 2 rows
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(five[3], CGRect(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5))
    }

    func testFit() {
        XCTAssertEqual(CanvasLayout.fit(aspect: 2, in: CGSize(width: 400, height: 400)),
                       CGSize(width: 400, height: 200))
        XCTAssertEqual(CanvasLayout.fit(aspect: 0.5, in: CGSize(width: 400, height: 400)),
                       CGSize(width: 200, height: 400))
    }
}
