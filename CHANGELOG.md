# Changelog

All notable changes to LogiCam Tuner are listed here. The project follows
[Semantic Versioning](https://semver.org): MAJOR for incompatible changes, MINOR for new features,
PATCH for fixes. The version lives in the `VERSION` file.

## [Unreleased]

### Added
- The preview and stream overlay work with the Mac's built-in camera and Continuity Camera. The overlay
  follows whichever camera an app is using, and returns to the chosen camera afterwards.
- For cameras without controls, the overlay and preview readout show the shutter speed, ISO, colour
  temperature and light level the camera reports with each frame.
- Session history records which camera each session used; `logicam who` lists every camera.
- The overlay can be minimised to a single line, and the menu-bar panel shows the live stream's stats
  in a section that folds open, with a button to bring back a closed overlay.

### Fixed
- The overlay could not be dragged: its SwiftUI content swallowed the clicks that should move it.

### Changed
- When LogiCam Tuner picks the camera mode itself, it prefers 16:9 and falls back to 30 fps for cameras
  that cannot reach the preview frame rate.

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
