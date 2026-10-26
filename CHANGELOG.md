# Changelog

All notable changes to LogiCam Tuner are listed here. The project follows
[Semantic Versioning](https://semver.org): MAJOR for incompatible changes, MINOR for new features,
PATCH for fixes. The version lives in the `VERSION` file.

## [Unreleased]

### Changed
- New original app icon and logo: a camera lens inside a tuning dial. The previous icon used an SF
  Symbol, which Apple's licence does not allow in app icons.
- README: logo, highlights and install instructions at the top, and screenshots of the stream overlay
  and the main window.
- The diagnostics log records dropped frames and stalled streams, and no longer records each routine
  check that a call is still using the camera.

### Fixed
- Smart Auto keeps the stream's frame rate in low light: it raises ISO to half of Max ISO before it
  lengthens frames. Calls in a dim room ran at about 15 fps.
- Smart Auto exposure no longer corrects back and forth when face detection misses a face for a moment:
  a missed face keeps counting for 8 seconds, then fades out.
- Smart Auto exposure no longer flashes on calls with a bright window in view. Corrections fade in over
  several frames instead of landing in one, allow for the camera brightening about twice as much as
  predicted instead of overshooting, and start only once an error lasts about a second. Faces are
  measured only on the frame they were found in, since a moving head soon leaves its box.
- Smart Auto measures again only once its change has reached the camera and four of the frames the
  camera really delivers have passed, and white balance waits for exposure changes. Shutter and gain
  are sent together.
- With 60 Hz anti-flicker at 60 fps, Smart Auto can use a 1/60 s shutter; it used 1/120 s plus gain.
- A capture session that stops, or stops delivering frames, restarts after 3 seconds instead of leaving
  the preview frozen and Smart Auto idle.
- The measured frame rate reads 0 when frames stop instead of keeping the last rate, and waits for
  enough frames after starting.

## [1.1.0] - 2026-10-18

### Added
- The preview and stream overlay work with the Mac's built-in camera and Continuity Camera. The overlay
  follows whichever camera an app is using, and returns to the chosen camera afterwards.
- For cameras without controls, the overlay and preview readout show the shutter speed, ISO, colour
  temperature and light level the camera reports with each frame.
- Session history records which camera each session used; `logicam who` lists every camera.
- The overlay can be minimised to a single line, and the menu-bar panel shows the live stream's stats
  in a section that folds open, with a button to bring back a closed overlay.

### Changed
- When LogiCam Tuner picks the camera mode itself, it prefers 16:9 and falls back to 30 fps for cameras
  that cannot reach the preview frame rate.

### Fixed
- The overlay could not be dragged: its SwiftUI content swallowed the clicks that should move it.

## [1.0.0] - 2026-10-18

First public release.

### Added
- Every image control Logi Options+ offers for the StreamCam, using standard UVC requests: shutter
  speed, ISO, HDR, low-light boost, white balance, brightness, contrast, saturation, sharpness, zoom,
  pan, tilt, focus and anti-flicker.
- Smart Auto exposure (face priority, hysteresis, flicker-safe shutter) and white balance (from
  neutral surfaces), with exposure compensation, warmth, minimum frame rate and maximum ISO settings.
- Main window with a full-resolution live preview (30 or 60 fps) beside the controls; menu-bar panel.
- Floating stream overlay: apps using the camera, resolution, configured and measured fps, format,
  exposure, white balance and more; recent camera sessions to compare apps.
- Fix for apps that pick a 5 fps camera mode (WhatsApp picks the StreamCam's 2304×1296): the camera
  is switched to 1080p at 30 fps.
- Presets per camera, with an optional preset applied when the camera connects; Open at login.
- `logicam` command-line tool (list, describe, get, set, reset, presets, `auto`, `who`, `version`),
  included in the app bundle.

### Fixed during development
- Preview drew the low-resolution analysis image; it now shows full 1080p frames, at about half the CPU.
- The camera stayed on after calls because the app mistook its own stream for another app.
- Anti-flicker offered "Auto", which the StreamCam rejects; only values the camera accepts are shown.
