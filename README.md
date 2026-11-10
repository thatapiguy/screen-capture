# ScreenCap

A small macOS screen recorder for tutorials. It records raw tracks and composes them later:
zoom, cursor, camera inset and background are all applied in the editor and at export, never
baked into the recording.

## Build

Requires Xcode 16+ on macOS 14+.

```bash
open ScreenCap.xcodeproj
```

Select the `ScreenCap` scheme and run.

### Keeping permissions between builds

By default the app is ad-hoc signed, so every rebuild looks like a different app to macOS and the
Screen Recording, Camera and Microphone grants stop applying. Sign with your own team to fix that.
Create `Config/Local.xcconfig` (it is git-ignored):

```
DEVELOPMENT_TEAM = YOURTEAMID
CODE_SIGN_IDENTITY = Apple Development
```

A free Apple ID added under Xcode › Settings › Accounts is enough. Don't pick the team in the
target's Signing tab: that edits the generated project file, which CI overwrites.

`ScreenCap.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
CI regenerates and commits it, so you only need XcodeGen if you change `project.yml` locally.

## Tests

```bash
swift test --package-path ScreenCapCore
```

## Using it

- Click the menu bar icon for the record panel: source, camera, microphone, system audio, frame rate, resolution.
- Hotkeys (rebindable in Settings): ⌥⌘R start/stop, ⌥⌘P pause/resume, ⌥⌘Z zoom here.
- While recording, click the menu bar icon to stop, or right-click it to pause.
- The editor opens when a recording stops. Space plays, ←/→ step a frame, S splits, ⌫ deletes the
  selection, Z adds a zoom, [ and ] trim to the playhead, ⌘Z/⇧⌘Z undo and redo, ⌘E exports.

## Recording bundle

Each recording is a `.reel` package in `~/Movies/ScreenCap/`:

| File | Contents |
|---|---|
| `project.json` | Facts about the recording: size, scale, fps, camera shape, `recording`/`complete` state |
| `screen.mov` | Screen video, HEVC, cursor not included |
| `camera.mov` | Webcam, raw and unmirrored (optional) |
| `mic.mov`, `system.mov` | One audio track each (optional) |
| `events.jsonl` | Cursor path, clicks, keystroke timing (no key contents), zoom markers |
| `edits.json` | Edit decisions: trims, cuts, zoom regions, camera layout, cursor, background, volumes |

Media files are written in one-second fragments, so a recording survives a crash; the editor only
ever writes `edits.json`.

## Layout

- `ScreenCap/App`: menu bar item, record panel, permissions, settings, hotkeys
- `ScreenCap/Capture`: `Recorder` (state machine), `CaptureEngine` (ScreenCaptureKit), `CameraEngine`,
  `MicEngine`, `MetadataRecorder`, `TrackWriter` and the shared `SessionClock`
- `ScreenCap/Project`: the `.reel` bundle on disk
- `ScreenCap/Render`: `CompositionBuilder`, `Compositor` and `Exporter`, one path for preview and export
- `ScreenCap/Editor`: editor model and views
- `ScreenCap/Overlays`: region picker, countdown, camera bubble
- `ScreenCapCore`: pure logic as a Swift package (timeline mapping, auto-zoom, zoom camera, layout), unit tested

## Extension points (not built)

Captions, annotations and text overlays would be new fields in `EditDecisions` drawn as extra
layers in `Compositor.startRequest`. Transitions and multi-clip projects would extend `Timeline`
and `CompositionBuilder`.
