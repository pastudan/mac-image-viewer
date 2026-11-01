import CanvasCore
import CoreGraphics
import XCTest

final class VideoBarTests: XCTestCase {
    func testWidePaneHasEverything() throws {
        let pane = CGRect(x: 100, y: 50, width: 640, height: 360)
        let bar = try XCTUnwrap(VideoBarLayout(pane: pane))
        XCTAssertNotNil(bar.playPause)
        XCTAssertNotNil(bar.mute)
        let current = try XCTUnwrap(bar.currentLabel)
        let duration = try XCTUnwrap(bar.durationLabel)
        // Left to right: buttons, current time, track, runtime. Nothing overlaps.
        XCTAssertLessThan(bar.mute!.maxX, current.minX)
        XCTAssertLessThan(current.maxX, bar.track.minX)
        XCTAssertLessThan(bar.track.maxX, duration.minX)
        for r in [bar.playPause!, bar.mute!, current, duration, bar.track, bar.trackHitArea] {
            XCTAssertTrue(pane.contains(r), "\(r) outside pane")
        }
        XCTAssertEqual(bar.strip.maxY, pane.maxY)
        XCTAssertEqual(bar.strip.height, VideoBarLayout.height)
    }

    func testNarrowPaneDropsLabelsThenButtons() throws {
        let medium = try XCTUnwrap(VideoBarLayout(pane: CGRect(x: 0, y: 0, width: 180, height: 120)))
        XCTAssertNotNil(medium.playPause)
        XCTAssertNil(medium.currentLabel)
        let small = try XCTUnwrap(VideoBarLayout(pane: CGRect(x: 0, y: 0, width: 80, height: 60)))
        XCTAssertNil(small.playPause)
        XCTAssertGreaterThanOrEqual(small.track.width, 16)
        XCTAssertNil(VideoBarLayout(pane: CGRect(x: 0, y: 0, width: 30, height: 30)))
    }

    func testButtonsMatchTileChrome() throws {
        let pane = CGRect(x: 20, y: 30, width: 500, height: 300)
        let bar = try XCTUnwrap(VideoBarLayout(pane: pane))
        let chrome = TileChrome.rects(in: pane, hasVideo: true)
        XCTAssertEqual(chrome[.playPause], bar.playPause)
        XCTAssertEqual(chrome[.mute], bar.mute)
    }

    func testFractionAlongTrack() throws {
        let bar = try XCTUnwrap(VideoBarLayout(pane: CGRect(x: 0, y: 0, width: 640, height: 360)))
        XCTAssertEqual(bar.fraction(atX: bar.track.minX), 0)
        XCTAssertEqual(bar.fraction(atX: bar.track.maxX), 1)
        XCTAssertEqual(bar.fraction(atX: bar.track.midX), 0.5, accuracy: 1e-9)
        XCTAssertEqual(bar.fraction(atX: -100), 0)
        XCTAssertEqual(bar.fraction(atX: 10_000), 1)
        XCTAssertTrue(bar.trackHitArea.contains(CGPoint(x: bar.track.midX, y: bar.track.midY + 8)))
    }
}
