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

- To add files, double-click them in Finder, drop them onto the window, or use **File > Open** (Cmd-O). Each time files are added, everything is re-arranged to leave as little black space as possible (see **Best fit** below).
- **Folder strip** (left side):
  - **File > Choose Strip Folder…** (Shift-Cmd-O) lists every image and video in a folder and all its subfolders, grouped by subfolder.
  - Scroll up and down through them.
  - **Drag** any thumbnail onto the canvas and it lands wherever you drop it, just like dragging from Finder. **Double-click** a thumbnail to add it straight away.
  - Drag the bar on the strip's right edge to resize it.
  - To hide it, click the **«** button at the top of the strip. The **sidebar button** in the title bar hides and shows it, and so does **View > Hide/Show Strip** (Ctrl-Cmd-S). The strip is always hidden when the app opens.
  - Use the refresh button to pick up new files. The folder only comes back after Touch ID (see below).
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
  - After you open (or save) a layout, **Cmd-S** fills in that layout's name, so pressing Return overwrites it. The dialog says so in orange, shows when it was last saved, and the button reads **Overwrite**. Type a different name and it switches to **Save**, to save a new layout instead.
- **Best fit:** the app looks at each picture's shape and picks the arrangement, order and pane sizes that leave the least black around them:
  - Tall phone photos get tall panes and panoramas get wide ones.
  - Each picture may also be trimmed by up to 10% at its edges to close the last gaps. Change this in **Settings > Layout**, from 0% to 25%.
  - It re-runs when you add or remove files, and when you resize the window. Once you drag, snap or resize panes yourself, your arrangement is kept until you add something or choose **Arrange > Best Fit** (Cmd-G).
- **Arrange > Even Out** (Shift-Cmd-G) gives every pane the same size instead.
- **View > Crop to Fill Panes** (Opt-Cmd-F) crops media to fill each pane completely.
- **Videos** loop and start muted:
  - Each video shows its **runtime** in the bottom-right corner.
  - **Hover** a video to bring up its control bar: play/pause, mute, the current time, a seek bar and the runtime. **Click or drag along the seek bar** to jump around the video; it pauses while you hold and resumes when you let go.
  - **Two-finger swipe left or right** on a video to scrub through it. A seek bar shows while your fingers are down and disappears the moment you lift them, and playback then resumes. One swipe across the pane covers the whole video. On a pinch-zoomed video, two fingers pan instead; Cmd-0 resets the zoom.
  - With a video selected, **Space** plays or pauses it and **M** mutes or unmutes it.
  - Unmuting one video mutes the others.
- Hover over a pane for its filename and a close button. **Delete** removes the selected pane, and **Shift-Cmd-Delete** clears the canvas.
- Snap the selected pane from the keyboard:
  - **Ctrl-Opt + arrows** for halves.
  - **Ctrl-Opt + U / I / J / K** for quarters.
  - **Ctrl-Opt + Return** to expand.
- Right-click a pane for Snap To, Play/Mute, Show in Finder and Remove.

## Opening the app, and Restore Last View

- Image Canvas always opens **empty**, with no images and no strip.
- **File > Restore Last View** (Shift-Cmd-R) brings back where you left off: the same pictures, pane sizes, zoom and strip. It asks for **Touch ID** first, or your Mac password. Cancelling or a failed fingerprint shows nothing.
- The last view is saved as you work, and when you quit, to `~/Library/Application Support/Image Canvas/Last View.json`. It holds file paths and the arrangement, not the pictures themselves. Opening the app and quitting without doing anything leaves the previous saved view alone.
## Privacy: emptied when the Mac locks

This is on by default. **Image Canvas > Settings… > Privacy** turns it off.

- When you **lock the screen** (Ctrl-Cmd-Q, or the lid), the **Mac sleeps**, the **screen saver** starts or you **switch user**, Image Canvas saves what was open and then **empties the window**. The canvas is cleared, the strip is closed, and its folder and thumbnails are dropped from memory.
- After you unlock, the window is empty. **Shift-Cmd-R** (File > Restore Last View) brings everything back after **Touch ID**, or your Mac password.
- **Image Canvas > Clear for Privacy** (Ctrl-Cmd-L) does the same thing right away.

## The strip's folder

- The strip's folder is **not** remembered in the app's preferences. It's kept only in the last-view file, and it always takes **Touch ID** to come back.
- With the strip open and no folder, you can **Choose Folder…** or click **Restore Last Folder**, which asks for Touch ID. **Restore Last View** also brings it back.

## Development

```sh
swift build       # debug build
swift test        # layout / snap unit tests
swift run         # runs unbundled (file-type registration needs the .app)
```

- `Sources/CanvasCore/` holds the geometry and is unit tested:
  - `Layout.swift` is the stained-glass layout. It's a binary tree of splits whose leaves are panes, so the panes always cover the canvas exactly. It also handles hit testing and the JSON encoding.
  - `SnapZone.swift` detects window edges and corners.
  - `Fit.swift` is the edge-trimming maths: how big a picture is drawn in a pane, and how much of the pane it covers.
  - `BestFit.swift` is the layout search. It places every divider where both sides get their contents' natural shape, then finds the split tree and order whose combined shape is closest to the window. Each search is limited to about 30 ms, and the result is never worse than an even split.
  - `Zoom.swift` covers pinch zoom and the hover-button positions.
  - `LayoutDocument.swift` is the saved-layout file format.
- `Sources/ImageCanvas/` holds the SwiftUI app:
  - The SwiftUI views only draw.
  - `InteractionView.swift` is a single AppKit view on top that receives all mouse, trackpad and file-drop input and maps it to panes through the model's geometry.
  - Videos play with `AVQueuePlayer` + `AVPlayerLooper`.

The app icon is a De Stijl grid drawn in code. To change it, edit the colours and line positions in `scripts/make-icon.swift`, run `scripts/make-icon.sh` to regenerate `Resources/AppIcon.png` and `Resources/AppIcon.icns`, then run `scripts/build-app.sh`.

End-to-end mouse check, which sends real mouse events through the window:

```sh
"$HOME/Applications/Image Canvas.app/Contents/MacOS/ImageCanvas" --self-test report.json a.jpg b.jpg c.jpg d.jpg
```
