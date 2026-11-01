# Image Canvas

A macOS viewer where every image and video you open shares one window, like panes of
stained glass. The panes always fill the window. Adding or moving one splits a
neighbour and the rest shrink to make room. Videos loop automatically.

## Build and install

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
scripts/build-app.sh
```

This builds a release binary, wraps it in `Image Canvas.app`, ad-hoc signs it,
copies it to `~/Applications`, and registers it with LaunchServices.

## Make it the default viewer

On first launch the app offers to become the default for JPEG, PNG, HEIC/HEIF,
GIF, WebP, TIFF, BMP, MP4, MOV and M4V. You can also do it any time from
**Image Canvas > Make Default Viewer…** (macOS may ask you to confirm).

Manual fallback: in Finder, select a file, **Get Info** (Cmd-I),
**Open with: Image Canvas**, then **Change All…**. Repeat per file type.

## Using it

- To add files, double-click them in Finder, drop them onto the window, or use **File > Open** (Cmd-O). Each time files are added, every pane is evened out to the same size.
- **Drag a pane** and a blue preview shows where it will land:
  - Over another pane's **edge**, it splits that pane and takes that side.
  - Over another pane's **centre**, the two panes swap places.
  - At the **window edge**, it takes that whole half and everything else shrinks into the other half.
  - At a **window corner**, it takes a quarter.
- **Drag the line between panes** to resize them.
- **Double-click** a pane to zoom it to the whole window, and double-click again to return.
- **Arrange > Even Out** (Cmd-G) gives every pane the same size.
- **View > Crop to Fill Panes** (Opt-Cmd-F) crops media to fill each pane instead of letterboxing it.
- **Videos** loop and start muted:
  - Hover for play/pause and mute buttons.
  - With a video selected, **Space** plays or pauses it and **M** mutes or unmutes it.
  - Unmuting one video mutes the others.
- Hover over a pane for its filename and a close button. **Delete** removes the selected pane, and **Shift-Cmd-Delete** clears the canvas.
- Snap the selected pane from the keyboard:
  - **Ctrl-Opt + arrows** for halves.
  - **Ctrl-Opt + U / I / J / K** for quarters.
  - **Ctrl-Opt + Return** to zoom.
- Right-click a pane for Snap To, Play/Mute, Show in Finder and Remove.

## Development

```sh
swift build       # debug build
swift test        # layout / snap unit tests
swift run         # runs unbundled (file-type registration needs the .app)
```

- `Sources/CanvasCore/` holds the geometry and is unit tested:
  - `Layout.swift` is the stained-glass layout. It's a binary tree of splits whose leaves are panes, so the panes always cover the canvas exactly.
  - `SnapZone.swift` detects window edges and corners.
- `Sources/ImageCanvas/` holds the SwiftUI app, the canvas model, the pane views and video playback (`AVQueuePlayer` + `AVPlayerLooper`).
