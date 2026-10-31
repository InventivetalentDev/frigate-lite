# Frigate Lite

A small native macOS viewer for [Frigate](https://frigate.video) cameras, made to stay open on a spare monitor all day without slowing the Mac down.

> **Unofficial.** This is an independent project that works with Frigate NVR. It is not made, sponsored or endorsed by Frigate, Inc. "Frigate" is a trademark of Frigate, Inc.

## Build and run

Needs macOS 14 or later and the Xcode command line tools (Swift 6).

```sh
./scripts/build-app.sh
open build/FrigateLite.app            # or: cp -R build/FrigateLite.app /Applications/
```

On first launch, Settings opens:

| Your Frigate port | URL | Login | Self-signed certificate |
|---|---|---|---|
| 5000 (internal, no auth) | `http://<host>:5000` | leave empty | off |
| 8971 (default, auth) | `https://<host>:8971` | your Frigate user | on |

macOS then asks for **Local Network** access. Allow it, or the app cannot reach Frigate. If it never asked and tiles stay on "Can't connect", turn it on in System Settings → Privacy & Security → Local Network.

The password is stored in the Keychain. The app is ad-hoc signed, so after a rebuild macOS may ask again for Keychain access (click "Always Allow") and for Local Network access.

## Using it

| Action | How |
|---|---|
| Focus one camera | Click it, or press `1`–`9` / `0` |
| Back to the grid | Click, `Esc` or `Space` |
| Next / previous camera | `→` / `←` |
| Refresh rates, camera group, hide cameras, image quality | **View** menu |
| Camera names on/off | `⌘L` |
| Keep window above others | `⌥⌘T` |
| Reload the camera list | `⌘R` |
| Full screen | `⌃⌘F` |

Tile status dots: **orange** = Frigate reports the camera offline (old frame shown). **Red** = the last fetch failed.

Camera order, `ui.dashboard`, friendly names and camera groups come from your Frigate config. If birdseye restream is on, **View → Camera Group → Birdseye** shows Frigate's server-side combined view as a single image.

## Why it is lighter than the Frigate web UI

1. **No browser engine.** Native AppKit and Core Animation.
2. **Still frames, not video.** It polls `/api/<camera>/latest.jpg` at a fixed rate: 1 fps for the grid and 5 fps for a focused camera by default. There are no video decoders and no MSE/WebRTC buffers that grow over time.
3. **One screen update per tick.** All tiles change in one Core Animation commit. The web UI runs about a dozen independent video streams, so some part of the screen changes almost constantly. DisplayLink compresses changed screen regions in software and sends them over USB, so constant change costs CPU continuously. With one commit per tick, the window changes once per second.
4. **Frames sized to the tile.** It asks Frigate for `height=<tile height in pixels>`, so Frigate does the downscale. JPEGs are decoded on background threads into the bitmap format Core Animation uses natively, so the main thread only swaps images.
5. **Nothing runs when you can't see it.** Polling stops completely when the window is hidden, minimised, fully covered by other windows, or on another Space, and when the screen is locked or asleep.

Each frame also costs the Frigate host a resize and JPEG encode. 12 cameras at 1 fps is 12 small encodes per second. The 5 fps grid option is 60, so pick it on purpose.

Measured against the bundled mock server (11 cameras, Apple Silicon, 30 s averages):

| Mode | App CPU (of one core) | Requests |
|---|---|---|
| Grid, 1 fps | ~3 % | 11/s |
| Grid, 5 fps | ~18–23 % | 54/s |
| One camera focused, 5 fps | ~2.4 % | 4.5/s |
| Hidden, or fully covered by another window | 0 % | 0/s |

Memory: over a 10-minute run at 5 fps (about 30,000 frames), the memory footprint shown in Activity Monitor stayed flat at about 24 MB. RSS moves between 80 and 180 MB because it also counts shared graphics memory.

Not measured: pausing on another Space, screen lock and display sleep. These use the same mechanism and are expected to work.

## Limits

- Frames come from Frigate's **detect** stream. That stream sets the resolution and the maximum useful rate, so the focused rate is capped at each camera's `detect.fps`. This is not full-resolution live video.
- macOS only for now. A Windows version would be a separate small native client using the same approach (one timer, one composited surface), not a shared cross-platform UI layer.

## Development

```sh
swift build                                   # debug build
python3 tools/mock_frigate.py                 # fake Frigate on :5055 with 12 moving test cameras
python3 tools/mock_frigate.py --auth cat:meow --tls --port 5057   # like port 8971
```

The mock prints the request rate and the requested heights every 10 s, so you can check FPS limits and pausing.

Any setting can be overridden for one run without being saved:

```sh
build/FrigateLite.app/Contents/MacOS/FrigateLite -baseURL http://127.0.0.1:5055 -gridFPS 2 -lastFocused kitchen
FRIGATELITE_PASSWORD=meow build/FrigateLite.app/Contents/MacOS/FrigateLite -baseURL https://127.0.0.1:5057 -username cat -allowSelfSigned YES
```

Dev-only flags:

- `-snapshotPath out.png [-snapshotDelay 6] [-snapshotQuit YES] [-snapshotSettings YES]`: write the camera view (or the Settings window) to a PNG. No Screen Recording permission needed.
- `-debugHideAt 10 -debugUnhideAt 30`: hide and unhide the app, to test pausing.
- `-debugAlwaysPoll YES`: keep refreshing while hidden or covered (for soak tests).

### Code map

| File | What it does |
|---|---|
| `ViewerWindowController.swift` | Refresh loop, pausing, focus/grid state, View menu |
| `MosaicView.swift` | Layer-tree grid, one-commit updates, click and key input |
| `FrigateClient.swift` | Login, `/api/config` parsing, frame fetch, JPEG decode |
| `Settings.swift` | UserDefaults and Keychain |
| `SettingsWindow.swift` | SwiftUI settings form |
| `AppDelegate.swift` | Menus, startup, dev snapshot hooks |

## License

MIT, see [LICENSE](LICENSE).
