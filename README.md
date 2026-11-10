# ScreenCap

A small macOS screen recorder for tutorials: record raw tracks, compose (zoom, camera inset) later.

Status: **M1** — menu bar app, permissions, display/window/region capture with microphone.

## Build

Requires Xcode 16+ on macOS 14+.

```bash
open ScreenCap.xcodeproj
```

Select the `ScreenCap` scheme and run. In *Signing & Capabilities*, pick your own team: with ad-hoc
signing macOS forgets the Screen Recording permission on every rebuild.

`ScreenCap.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
CI regenerates and commits it, so you only need XcodeGen if you change `project.yml` locally.

## Tests

```bash
swift test --package-path ScreenCapCore
```

## Layout

- `ScreenCap/App` — menu bar item, record panel, permissions
- `ScreenCap/Capture` — `Recorder` (state machine), `CaptureEngine` (ScreenCaptureKit), `MicEngine`, `TrackWriter`
- `ScreenCap/Overlays` — region picker
- `ScreenCapCore` — pure logic as a Swift package, unit tested

Recordings are saved to `~/Movies/ScreenCap/Recording <date>.reel/` as separate files per track
(`screen.mov`, `mic.mov`).
