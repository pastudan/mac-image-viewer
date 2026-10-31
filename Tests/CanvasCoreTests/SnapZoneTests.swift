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
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 60), in: size), .topLeft)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 930, y: 5), in: size), .topRight)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 5, y: 120), in: size), .leftHalf)
        XCTAssertEqual(SnapZone.zone(for: CGPoint(x: 850, y: 5), in: size), .topHalf)
    }

    func testDegenerateCanvas() {
        XCTAssertNil(SnapZone.zone(for: .zero, in: .zero))
    }
}
