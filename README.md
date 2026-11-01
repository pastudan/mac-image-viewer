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
- **Click** a pane to select it. A click only ever selects the pane under the pointer and never moves anything.
- **Drag the line between panes** to resize them. The cursor changes and the line turns blue when you're on it.
- **Pinch** on the trackpad to zoom inside the pane under your fingers, keeping the spot under your fingers in place:
  - **Two-finger scroll**, or **Option-drag**, pans a zoomed pane.
  - **Two-finger double-tap** zooms in, or back out.
  - With a mouse, **Command-scroll** zooms.
  - **Cmd = / Cmd - / Cmd 0** zoom the selected pane in, out, or back to fit.
- **Double-click** a pane to expand it to the whole window, and double-click again to return.
- **File > Save Layout…** (Cmd-S) saves the open files, the pane arrangement and each pane's zoom. **File > Open Layout** restores one, and **File > Show Layouts Folder** shows where they're kept: `~/Library/Application Support/Image Canvas/Layouts/` (one JSON file each). Panes whose files have since moved are skipped, and you're told which ones.
- **Arrange > Even Out** (Cmd-G) gives every pane the same size.
- **View > Crop to Fill Panes** (Opt-Cmd-F) crops media to fill each pane instead of letterboxing it.
- **Videos** loop and start muted:
  - **Two-finger swipe left or right** on a video to scrub through it. A seek bar shows while your fingers are down and disappears the moment you lift them, and playback then resumes. One swipe across the pane covers the whole video. On a pinch-zoomed video, two fingers pan instead; Cmd-0 resets the zoom.
  - Hover for play/pause and mute buttons.
  - With a video selected, **Space** plays or pauses it and **M** mutes or unmutes it.
  - Unmuting one video mutes the others.
- Hover over a pane for its filename and a close button. **Delete** removes the selected pane, and **Shift-Cmd-Delete** clears the canvas.
- Snap the selected pane from the keyboard:
  - **Ctrl-Opt + arrows** for halves.
  - **Ctrl-Opt + U / I / J / K** for quarters.
  - **Ctrl-Opt + Return** to expand.
- Right-click a pane for Snap To, Play/Mute, Show in Finder and Remove.

## Privacy lock (optional)

**Image Canvas > Settings… (Cmd-,) > Require Touch ID to show images after the Mac sleeps.** It's off by default.

- When it's on and the Mac sleeps, the canvas is replaced by a lock screen and videos pause. Your images aren't drawn behind it at all.
- On wake, if Image Canvas is the app in front, it asks for Touch ID straight away. Otherwise click **Unlock with Touch ID**. Your Mac password works as a fallback.
- **Also lock when the screen locks or the screen saver starts** is on by default once the main setting is on, because closing the lid often locks the screen without a full sleep.
- **Image Canvas > Lock Now** (Ctrl-Cmd-L) locks immediately.
- Macs don't have Face ID. On a Mac without Touch ID, the password is used instead.

## Development

```sh
swift build       # debug build
swift test        # layout / snap unit tests
swift run         # runs unbundled (file-type registration needs the .app)
```

- `Sources/CanvasCore/` holds the geometry and is unit tested:
  - `Layout.swift` is the stained-glass layout. It's a binary tree of splits whose leaves are panes, so the panes always cover the canvas exactly. It also handles hit testing and the JSON encoding.
  - `SnapZone.swift` detects window edges and corners.
  - `Zoom.swift` covers pinch zoom and the hover-button positions.
  - `LayoutDocument.swift` is the saved-layout file format.
- `Sources/ImageCanvas/` holds the SwiftUI app:
  - The SwiftUI views only draw.
  - `InteractionView.swift` is a single AppKit view on top that receives all mouse, trackpad and file-drop input and maps it to panes through the model's geometry.
  - Videos play with `AVQueuePlayer` + `AVPlayerLooper`.

End-to-end mouse check, which sends real mouse events through the window:

```sh
"$HOME/Applications/Image Canvas.app/Contents/MacOS/ImageCanvas" --self-test report.json a.jpg b.jpg c.jpg d.jpg
```
