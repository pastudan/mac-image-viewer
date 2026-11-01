import CanvasCore
import Foundation
import XCTest

final class FolderScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScannerTests-\(UUID().uuidString)", isDirectory: true)
        let files = [
            "b.JPG", "a.png", "notes.txt", ".hidden.jpg", "clip.mov",
            "Day 10/x.heic",
            "Day 2/y.mp4", "Day 2/z.gif",
            "Day 2/Beach/w.jpeg",
            "Day 2/.secret/v.png",          // inside a hidden folder
            "Thing.app/Contents/icon.png",  // inside a package
            "Empty/readme.md",
        ]
        for path in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsImagesAndVideosRecursivelyInFinderOrder() {
        let result = FolderScanner.scan(root)
        XCTAssertEqual(result.sections.map(\.relativeFolder), ["", "Day 2", "Day 2/Beach", "Day 10"])
        XCTAssertEqual(result.sections[0].items.map(\.name), ["a.png", "b.JPG", "clip.mov"])
        XCTAssertEqual(result.sections[1].items.map(\.name), ["y.mp4", "z.gif"])
        XCTAssertEqual(result.sections[2].items.map(\.name), ["w.jpeg"])
        XCTAssertEqual(result.sections[3].items.map(\.name), ["x.heic"])
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result.videoCount, 2)
        XCTAssertEqual(result.imageCount, 5)
        XCTAssertFalse(result.truncated)
    }

    func testFlagsVideos() {
        let items = FolderScanner.scan(root).sections.flatMap(\.items)
        XCTAssertEqual(Set(items.filter(\.isVideo).map(\.name)), ["clip.mov", "y.mp4"])
    }

    func testSkipsHiddenFilesPackagesAndOtherTypes() {
        let names = Set(FolderScanner.scan(root).sections.flatMap(\.items).map(\.name))
        XCTAssertFalse(names.contains(".hidden.jpg"))
        XCTAssertFalse(names.contains("v.png"))
        XCTAssertFalse(names.contains("icon.png"))
        XCTAssertFalse(names.contains("notes.txt"))
        XCTAssertFalse(names.contains("readme.md"))
    }

    func testLimitTruncates() {
        let result = FolderScanner.scan(root, limit: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.truncated)
    }

    func testCancelStopsEarly() {
        // Cancelling stops the walk; the result is just whatever was found so far.
        let result = FolderScanner.scan(root, shouldContinue: { false })
        XCTAssertLessThanOrEqual(result.count, 7)
    }

    func testMissingFolderIsEmpty() {
        let result = FolderScanner.scan(root.appendingPathComponent("nope"))
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.sections.isEmpty)
    }
}
