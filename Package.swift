// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ImageCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure geometry (snap zones, grid layout) so it can be unit tested without AppKit.
        .target(name: "CanvasCore"),
        .executableTarget(
            name: "ImageCanvas",
            dependencies: ["CanvasCore"]
        ),
        .testTarget(
            name: "CanvasCoreTests",
            dependencies: ["CanvasCore"]
        ),
    ]
)
