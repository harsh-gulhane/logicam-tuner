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

## Pull requests

`main` is protected: every change, including the maintainer's, lands through a pull request once CI's
`build` check passes. Branch from `main`, push the branch and open a pull request against `main`.
Pull requests are squash-merged, so the pull request title becomes the commit message: keep it short,
in Conventional Commit style (`feat: …`, `fix: …`, `docs: …`). Merged branches are deleted.

## Guidelines

- Keep changes focused, and add a check to `Tests/LogiCamKitChecks` for new behaviour where possible.
- Hardware behaviour differs between cameras. Say in the pull request which camera and macOS version
  you tested on, and what you could not test.
- Don't add Logitech code, logos or other assets. Camera behaviour should come from the standard UVC
  interface or from your own measurements.

## Reporting another camera

Open an issue with `logicam list` and `logicam describe` output and what worked. That is how the
"Tested hardware" table grows.

## Releasing (maintainers)

1. Update `VERSION` (semantic versioning) and move the `## [Unreleased]` notes in `CHANGELOG.md` under a new
   `## [x.y.z] - YYYY-MM-DD` heading. Open a pull request (`release: x.y.z`) and merge it once CI passes.
2. Update your local `main` (`git checkout main && git pull`), then run `scripts/release.sh x.y.z`. It tags `vx.y.z`; the Release workflow runs the checks, builds the universal
   app and publishes the zip and its checksum on GitHub; the script then updates the cask in
   [harsh-gulhane/homebrew-tap](https://github.com/harsh-gulhane/homebrew-tap).
