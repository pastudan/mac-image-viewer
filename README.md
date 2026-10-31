# Image Canvas

A macOS image viewer where every image you open lands on one shared canvas.
Drag images around, and drop them on an edge or corner to snap them into a
half or quarter of the window, like Windows Snap.

## Build and install

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
scripts/build-app.sh
```

This builds a release binary, wraps it in `Image Canvas.app`, ad-hoc signs it,
copies it to `~/Applications`, and registers it with LaunchServices.

## Make it the default viewer

On first launch the app offers to become the default for JPEG, PNG, HEIC/HEIF,
GIF, WebP, TIFF and BMP. You can also do it any time from
**Image Canvas > Make Default Image Viewer…** (macOS may ask you to confirm).

Manual fallback: in Finder, select an image, **Get Info** (Cmd-I),
**Open with: Image Canvas**, then **Change All…**. Repeat per file type.

## Using it

- Double-click images in Finder, drop them onto the window, or use **File > Open** (Cmd-O). Each one becomes a tile on the same canvas.
- **Drag** a tile to move it. Drop it with the pointer at an **edge** for a half, or near a **corner** for a quarter. A blue preview shows where it will go.
- **Drag a snapped tile away** and it goes back to its old size.
- **Double-click** a tile to fill the canvas; double-click again to put it back.
- **Resize** with the handle in the bottom-right corner (proportions are kept).
- Hover for the filename and a close button. **Delete** removes the selected tile, and **Shift-Cmd-Delete** clears the canvas.
- **Arrange > Tile All** (Cmd-G) puts every image in a grid.
- Keyboard snapping of the selected tile: **Ctrl-Opt + arrows** for halves, **Ctrl-Opt + U / I / J / K** for quarters, **Ctrl-Opt + Return** to fill.
- Right-click a tile for Snap To, Show in Finder, and Remove.
- Put the window in full screen to snap against the whole screen.

## Development

```sh
swift build       # debug build
swift test        # snap-zone / layout unit tests
swift run         # runs unbundled (file-type registration needs the .app)
```

The layout is split into two parts:

- `Sources/CanvasCore/` holds the geometry: snap zones and grid layout. These are pure functions and are unit tested.
- `Sources/ImageCanvas/` holds the SwiftUI app, the canvas model and the views.
