import CanvasCore
import CoreGraphics
import XCTest

final class ScrubTests: XCTestCase {
    func testHorizontalSwipeOnVideoLocksToScrub() {
        var g = ScrollGesture()
        XCTAssertEqual(g.feed(CGSize(width: 2, height: 0), canScrub: true), .undecided)
        XCTAssertEqual(g.feed(CGSize(width: 3, height: 1), canScrub: true), .scrub)
        // Drifting vertically later doesn't change the decision.
        XCTAssertEqual(g.feed(CGSize(width: 0, height: 40), canScrub: true), .scrub)
    }

    func testVerticalSwipeOrImageLocksToPan() {
        var v = ScrollGesture()
        XCTAssertEqual(v.feed(CGSize(width: 1, height: 6), canScrub: true), .pan)
        var image = ScrollGesture()
        XCTAssertEqual(image.feed(CGSize(width: 10, height: 0), canScrub: false), .pan)
    }

    func testAdvanceMapsPaneWidthToWholeVideo() {
        // A full swipe across an 800pt pane covers a 60s video.
        XCTAssertEqual(ScrubMath.advance(0, by: 800, paneWidth: 800, duration: 60), 60, accuracy: 1e-9)
        XCTAssertEqual(ScrubMath.advance(30, by: 200, paneWidth: 800, duration: 60), 45, accuracy: 1e-9)
        // Fingers moving left go back.
        XCTAssertEqual(ScrubMath.advance(30, by: -200, paneWidth: 800, duration: 60), 15, accuracy: 1e-9)
    }

    func testAdvanceClampsAndHandlesSmallPanes() {
        XCTAssertEqual(ScrubMath.advance(55, by: 500, paneWidth: 800, duration: 60), 60)
        XCTAssertEqual(ScrubMath.advance(5, by: -500, paneWidth: 800, duration: 60), 0)
        // A 100pt pane scrubs as if it were 400pt wide.
        XCTAssertEqual(ScrubMath.advance(0, by: 100, paneWidth: 100, duration: 40), 10, accuracy: 1e-9)
        XCTAssertEqual(ScrubMath.advance(3, by: 50, paneWidth: 800, duration: 0), 0)
    }

    func testTimecode() {
        XCTAssertEqual(ScrubMath.timecode(7.9), "0:07")
        XCTAssertEqual(ScrubMath.timecode(754), "12:34")
        XCTAssertEqual(ScrubMath.timecode(3723), "1:02:03")
        XCTAssertEqual(ScrubMath.timecode(.nan), "0:00")
        XCTAssertEqual(ScrubMath.timecode(-3), "0:00")
    }
}
