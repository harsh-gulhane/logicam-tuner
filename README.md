# CamDial

A small macOS menu-bar app and CLI for adjusting USB webcams — built for Logitech
webcams such as the StreamCam, and usable with any UVC camera.

CamDial talks to the camera directly with standard USB Video Class (UVC) control
requests, the same mechanism Logitech's own agent uses. It does not need Logi
Options+, Logi Tune, a kernel extension or a driver.

> CamDial is an independent project and is not affiliated with or endorsed by Logitech.

## Features

- Exposure (mode, time, gain, frame-rate priority, backlight compensation)
- Focus (auto/manual) and white balance (auto/manual, in kelvin)
- Brightness, contrast, saturation, sharpness, gamma, hue — whatever the camera advertises
- Digital zoom, pan and tilt
- Anti-flicker (50/60 Hz)
- Presets per camera, with an optional preset applied automatically whenever that camera connects
- Live preview (off by default, so the camera light stays off)
- Controls are discovered from the camera's own descriptor, so only supported controls appear

Logitech-only features such as auto-framing (RightSight), Show Mode and HDR use
vendor extension units whose protocol is not public. CamDial lists those units
but does not drive them.

## Install

Requires macOS 14 or later and Swift 5.10+ (Xcode or the Command Line Tools).

```sh
./scripts/build-app.sh          # builds build/CamDial.app (universal, ad-hoc signed)
open build/CamDial.app
```

Copy `build/CamDial.app` to `/Applications` to keep it. Because the build is
ad-hoc signed, another Mac will warn on first launch; right-click → Open.

## CLI

```sh
swift build -c release --product camdial
.build/release/camdial list
.build/release/camdial describe
.build/release/camdial get
.build/release/camdial set brightness=140 white_balance_auto=off white_balance=4500
.build/release/camdial set exposure_mode=auto
.build/release/camdial preset save desk
.build/release/camdial preset apply desk
.build/release/camdial reset
```

Use `--camera <index|serial>` when several cameras are attached and `--json` for
scripting.

## Notes

- **Logi Options+ / Logi Tune running at the same time.** They can reapply their own
  saved settings, for example when a video stream starts. If settings seem to revert,
  quit the Logitech app or set the same values there.
- **Settings while idle.** CamDial writes to the camera even when no app is streaming.
  The live preview is the quickest way to see the effect.
- **"Disabled by auto mode".** Many cameras (including the StreamCam) report UVC's
  "disabled by automatic mode" flag permanently, so CamDial decides whether a control
  is locked from the current value of its auto control instead.

## Tested hardware

| Camera | USB ID | Firmware | Result |
| --- | --- | --- | --- |
| Logitech StreamCam | 046d:0893 | 0x0317 | Reading and writing all 18 advertised standard controls, macOS 27.0.1 |

Reports for other cameras are welcome: include `camdial list` and `camdial describe` output.

## Development

```sh
swift build
swift run CamDialKitChecks      # offline checks, including a real StreamCam descriptor fixture
```

`docs/logitech-options-plus.md` records how Logi Options+ communicates with the camera.

## License

MIT
