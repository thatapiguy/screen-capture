# Changelog

Each `## x.y.z` section becomes the notes of the GitHub release for tag `vx.y.z`.

## 0.1.0

First release.

### Recording
- Record a full display, a single window or a dragged region, on any connected display.
- 30, 60 or 120 fps (where the display supports it) at native Retina resolution, or capped at 1440p/1080p.
- Camera with a floating, resizable preview; microphone with a level meter; optional system audio.
- Global hotkeys for start/stop, pause/resume and "zoom here", with a 3-2-1 countdown.
- Every source is saved as its own track in a `.reel` bundle, with the cursor, clicks and typing activity
  stored as data. Nothing is baked into the video.
- Recordings are written incrementally and are recovered after a crash.

### Editing
- Automatic zooms around clicks and typing, with adjustable sensitivity.
- Zoom segments on the timeline: move, resize, set the level, or drag a rectangle on the preview to
  choose exactly what is framed.
- Trim, split and ripple delete, plus one-click removal of long silences.
- Cursor size, smoothing, click highlights and matching cursor shapes (arrow, I-beam, pointing hand…).
- Camera inset position, size, shape, border and hide segments; optional padded background.
- Undo and redo for everything.

### Export
- MP4 in H.264 or HEVC at 1080p, 1440p, 4K or source size, 30 or 60 fps, with Small/Balanced/High quality.
- Animated GIF for short clips.
- Copy the exported file to the clipboard or drag it straight into another app.

### Known limitations
- The app is not notarized yet. See the README for how to open it the first time.
- In window mode, moving the window while recording offsets the cursor.
