import CanvasCore
import CoreGraphics
import Foundation
import XCTest

final class InteractionGeometryTests: XCTestCase {
    typealias L = LayoutNode<String>
    let size = CGSize(width: 1200, height: 800)
    var canvas: CGRect { CGRect(origin: .zero, size: size) }

    /// Four quadrants, split into columns first: a over b on the left, c over d on the right.
    var quads: L { L.balanced(["a", "b", "c", "d"], in: size)! }

    // MARK: Hit testing

    func testLeafAtPointPicksTheTileUnderThePointer() {
        let l = quads
        let f = l.frames(in: canvas)
        for id in ["a", "b", "c", "d"] {
            let r = f[id]!
            XCTAssertEqual(l.leaf(at: CGPoint(x: r.midX, y: r.midY), in: canvas), id)
        }
        XCTAssertNil(l.leaf(at: CGPoint(x: -5, y: 10), in: canvas))
    }

    func testDividerNearPoint() {
        let l = L.balanced(["a", "b"], in: size)! // a | b, divider at x = 600
        XCTAssertEqual(l.divider(near: CGPoint(x: 603, y: 400), in: canvas)?.axis, .columns)
        XCTAssertNil(l.divider(near: CGPoint(x: 620, y: 400), in: canvas))
        // Outside the divider's span doesn't count.
        XCTAssertNil(l.divider(near: CGPoint(x: 600, y: 900), in: canvas))
    }

    func testDividerNearPicksClosestOfNested() {
        let l = quads
        let ds = l.dividers(in: canvas)
        XCTAssertEqual(ds.count, 3)
        // Near the horizontal divider in the left column.
        let left = ds.first { $0.axis == .rows && $0.container.minX == 0 }!
        let hit = l.divider(near: CGPoint(x: 300, y: left.position + 2), in: canvas)
        XCTAssertEqual(hit?.path, left.path)
    }

    func testDraggingDividerMovesOnlyThatSplit() {
        let l = quads
        let left = l.dividers(in: canvas).first { $0.axis == .rows && $0.container.minX == 0 }!
        let moved = l.settingRatio(0.25, at: left.path)
        let f = moved.frames(in: canvas)
        XCTAssertEqual(f["a"]!.height, 200, accuracy: 0.001)
        XCTAssertEqual(f["b"]!.height, 600, accuracy: 0.001)
        // Right column untouched.
        XCTAssertEqual(f["c"]!.height, 400, accuracy: 0.001)
        XCTAssertEqual(f["d"]!.height, 400, accuracy: 0.001)
    }

    // MARK: Pinch zoom

    func testZoomKeepsPointUnderFingersFixed() {
        let pane = CGSize(width: 400, height: 300)
        let p = CGPoint(x: 100, y: 200)
        let z = ZoomTransform.identity.zoomed(by: 2, at: p, in: pane)
        XCTAssertEqual(z.scale, 2)
        // The content point that was under p (p itself, at identity) is still under p.
        let r = z.contentRect(in: pane)
        XCTAssertEqual(r.minX + p.x * z.scale, p.x, accuracy: 0.001)
        XCTAssertEqual(r.minY + p.y * z.scale, p.y, accuracy: 0.001)
    }

    func testZoomClampsScaleAndCoverage() {
        let pane = CGSize(width: 400, height: 300)
        XCTAssertEqual(ZoomTransform.identity.zoomed(by: 0.5, at: .zero, in: pane), .identity)
        XCTAssertEqual(ZoomTransform.identity.zoomed(by: 1000, at: .zero, in: pane).scale, ZoomTransform.maxScale)
        let z = ZoomTransform.identity.zoomed(by: 3, at: CGPoint(x: 200, y: 150), in: pane)
        // Panning far never exposes empty space: content still covers the pane.
        for delta in [CGSize(width: 5000, height: 5000), CGSize(width: -5000, height: -5000)] {
            let r = z.panned(by: delta, in: pane).contentRect(in: pane)
            XCTAssertLessThanOrEqual(r.minX, 0.001)
            XCTAssertLessThanOrEqual(r.minY, 0.001)
            XCTAssertGreaterThanOrEqual(r.maxX, pane.width - 0.001)
            XCTAssertGreaterThanOrEqual(r.maxY, pane.height - 0.001)
        }
    }

    func testZoomingBackOutResets() {
        let pane = CGSize(width: 400, height: 300)
        let z = ZoomTransform.identity.zoomed(by: 4, at: CGPoint(x: 10, y: 10), in: pane)
        XCTAssertEqual(z.zoomed(by: 0.1, at: CGPoint(x: 300, y: 10), in: pane), .identity)
    }

    // MARK: Chrome

    func testChromeRectsSitInsidePane() {
        let pane = CGRect(x: 600, y: 400, width: 600, height: 400)
        let rects = TileChrome.rects(in: pane, hasVideo: true)
        XCTAssertEqual(Set(rects.keys), [.close, .playPause, .mute])
        for r in rects.values { XCTAssertTrue(pane.contains(r)) }
        XCTAssertEqual(Set(TileChrome.rects(in: pane, hasVideo: false).keys), [.close])
        XCTAssertTrue(TileChrome.rects(in: CGRect(x: 0, y: 0, width: 40, height: 40), hasVideo: true).isEmpty)
    }

    // MARK: Saved layouts

    func testLayoutDocumentRoundTrip() throws {
        var l = quads
        let div = l.dividers(in: canvas)[0]
        l = l.settingRatio(0.3, at: div.path)
        let zoom = ZoomTransform(scale: 2.5, offset: CGPoint(x: -0.4, y: -0.2))
        let doc = LayoutDocument(name: "Test", savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 cropToFill: true, layout: l) { id in
            LayoutDocument.Item(path: "/tmp/\(id).jpg", zoom: id == "b" ? zoom : .identity)
        }
        XCTAssertEqual(doc.items.map(\.path), ["/tmp/a.jpg", "/tmp/b.jpg", "/tmp/c.jpg", "/tmp/d.jpg"])

        let data = try doc.encoded()
        let back = try LayoutDocument.decode(data)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.items[1].zoom, zoom)

        // Leaves map back to the same geometry.
        let restored = back.layout!.compactMapIDs { back.items[$0].path }
        let original = l.compactMapIDs { "/tmp/\($0).jpg" }
        XCTAssertEqual(restored, original)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"axis\" : \"columns\""))
    }

    func testMissingFilesDropOutAndSiblingsExpand() {
        let doc = LayoutDocument(name: "x", savedAt: Date(), cropToFill: false,
                                 layout: L.balanced(["a", "b"], in: size)) { LayoutDocument.Item(path: $0) }
        // Pretend b's file is gone.
        let restored = doc.layout!.compactMapIDs { doc.items[$0].path == "b" ? nil : doc.items[$0].path }
        XCTAssertEqual(restored, .leaf("a"))
    }

    func testFileNameSanitising() {
        XCTAssertEqual(LayoutDocument.fileName(for: "Mood board 2/3: final"), "Mood board 2-3- final.json")
        XCTAssertEqual(LayoutDocument.fileName(for: "  ..  "), "Layout.json")
    }
}
