# Contributing to LogiCam Tuner

Thanks for helping! Bug reports, camera reports and pull requests are all welcome.

## Build and check

Requires macOS 14 or later and Swift 5.10+ (Xcode or the Command Line Tools).

```sh
swift build
swift run LogiCamKitChecks      # offline checks; no camera needed
./scripts/build-app.sh          # builds "build/LogiCam Tuner.app"
```

CI runs the same three steps on every pull request.

## Layout

- `Sources/CUSBTransport` — small C layer that sends UVC control requests through IOKit.
- `Sources/LogiCamKit` — camera discovery, controls, Smart Auto, frame analysis, camera users.
- `Sources/LogiCamTunerApp` — the SwiftUI app (window, menu-bar panel, overlay).
- `Sources/logicam` — the command-line tool.
- `Tests/LogiCamKitChecks` — offline checks, including a real StreamCam descriptor fixture and
  simulated cameras for the auto-exposure and white-balance controllers.

## Guidelines

- Keep changes focused, and add a check to `Tests/LogiCamKitChecks` for new behaviour where possible.
- Hardware behaviour differs between cameras. Say in the pull request which camera and macOS version
  you tested on, and what you could not test.
- Don't add Logitech code, logos or other assets. Camera behaviour should come from the standard UVC
  interface or from your own measurements.

## Reporting another camera

Open an issue with `logicam list` and `logicam describe` output and what worked. That is how the
"Tested hardware" table grows.
