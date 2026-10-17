# CamDial

A macOS menu-bar app and CLI for adjusting USB webcams — built for Logitech webcams such as the
StreamCam, and usable with any UVC camera. It covers everything Logi Options+ offers for the
camera image, and adds **Smart Auto**: exposure and white balance that work better than the
camera's own automatics.

CamDial talks to the camera directly with standard USB Video Class (UVC) control requests, the
same mechanism Logitech's own agent uses. It does not need Logi Options+, Logi Tune, a kernel
extension or a driver.

> CamDial is an independent project and is not affiliated with or endorsed by Logitech.

## Controls

| Options+ name | CamDial | UVC control |
| --- | --- | --- |
| Auto exposure | Exposure mode: Camera / Smart / Manual | exposure mode |
| Shutter speed | Shutter speed (1/30 s …), in stops | exposure time |
| ISO | ISO (gain) | gain |
| Low light compensation | Low-light boost | auto-exposure priority |
| HDR | HDR (backlight compensation) | backlight compensation |
| White balance | Mode: Camera / Smart / Manual, temperature in kelvin | white balance |
| Brightness, contrast, saturation, sharpness | same | processing unit |
| Zoom, pan, tilt | same | camera terminal |
| Focus | Autofocus, focus | camera terminal |
| Anti-flicker | Anti-flicker (50/60 Hz) | power-line frequency |

Controls are discovered from the camera's own descriptor, so only supported controls appear. Gamma,
hue, roll (the StreamCam's portrait/landscape sensor) and others show up when a camera has them.

Plus: presets per camera (one can apply automatically whenever the camera connects), a live
preview (off by default), and Open at login.

## Smart Auto

Pick **Smart** for exposure, white balance or both. While any app (Zoom, Meet, FaceTime, OBS…) is
using the camera, CamDial looks at a small copy of the video on your Mac and steers the camera's
manual controls itself:

- **Faces first.** Exposure meters detected faces, blended with the scene, so a bright window behind
  you no longer leaves your face dark.
- **No breathing.** Exposure only starts correcting at a clearly visible error (0.25 EV) and stops close
  to target; white balance has the same kind of hysteresis. The picture settles and stays put.
- **White balance from neutral surfaces.** Only near-grey, well-exposed pixels outside faces count, so a
  coloured shirt or wall does not pull the colour. With too few neutral pixels, it holds the current
  setting instead of guessing.
- **Clean and flicker-free.** Shutter time is spent before gain, and snapped to whole mains periods
  so lights do not band. You choose how low the frame rate may go in low light (30, 15 or 7.5 fps)
  and the highest ISO.
- **Your taste.** Exposure compensation (±2 EV) and a warmth slider.

On a StreamCam in a dim room, the camera's own auto exposure chose 1/25 s at full gain and its auto
white balance left whites amber (5230 K) and drifted for seconds. Smart Auto settled at 1/17 s,
which keeps 15 fps, and neutral whites at about 3400 K within roughly two seconds. Measured with
`camdial auto --watch` on one camera and one room; your results will differ.

Smart Auto never turns the camera on by itself: it runs only while another app is streaming (or the
preview is open). Video is analysed in memory and never recorded or sent anywhere. When CamDial
quits, the camera's own automatics are switched back on; Smart Auto resumes at the next launch.

## Install

Requires macOS 14 or later and Swift 5.10+ (Xcode or the Command Line Tools).

```sh
./scripts/build-app.sh          # builds build/CamDial.app (universal, ad-hoc signed)
open build/CamDial.app
```

Copy `build/CamDial.app` to `/Applications` to keep it. Because the build is ad-hoc signed,
another Mac will warn on first launch; right-click → Open. macOS asks for camera access the first
time Smart Auto or the preview needs video.

## CLI

```sh
swift build -c release --product camdial
CAMDIAL=$(swift build -c release --show-bin-path)/camdial
$CAMDIAL list
$CAMDIAL describe
$CAMDIAL get
$CAMDIAL set brightness=140 white_balance_auto=off white_balance=4500
$CAMDIAL set exposure_mode=auto
$CAMDIAL preset save desk
$CAMDIAL preset apply desk
$CAMDIAL reset
$CAMDIAL auto                    # Smart Auto until Ctrl-C (turns the camera on)
$CAMDIAL auto exposure --bias -0.3 --min-fps 15
$CAMDIAL auto --watch            # print measurements only; change nothing
```

Use `--camera <index|serial>` when several cameras are attached and `--json` for scripting.

## Notes

- **Logi Options+ / Logi Tune running at the same time.** They can reapply their own saved settings.
  In testing, values CamDial set (including Smart Auto's) stayed in place with Options+ running.
- **Detecting other apps.** CamDial asks CoreMediaIO whether the camera is streaming. While Smart Auto
  is streaming itself, it pauses for about a second every 20 seconds to check whether the other app
  is still there. (`AVCaptureDevice.isInUseByAnotherApplication` did not report other apps on macOS 27.)
- **"Disabled by auto mode".** Many cameras (including the StreamCam) report UVC's "disabled by
  automatic mode" flag permanently, so CamDial decides whether a control is locked from the current
  value of its auto control instead.
- **Logitech-only features.** Auto-framing (RightSight) and Show Mode use vendor extension units whose
  protocol is not public. CamDial lists those units but does not drive them. On the StreamCam, Options+
  offers no other image controls.
- **Diagnostics.** `log stream --predicate 'subsystem == "io.github.camdial"'` shows when Smart Auto
  starts and stops.

## Tested hardware

| Camera | USB ID | Firmware | Result |
| --- | --- | --- | --- |
| Logitech StreamCam | 046d:0893 | 0x0317 | All 18 advertised standard controls and Smart Auto, macOS 27.0.1 |

Reports for other cameras are welcome: include `camdial list` and `camdial describe` output.

## Development

```sh
swift build
swift run CamDialKitChecks      # offline checks, including a real StreamCam descriptor fixture
```

The checks run the exposure and white-balance controllers against simulated cameras whose behaviour
(weak gain, exaggerated tone curve, flicker-safe shutter steps) was measured on a real StreamCam.

`docs/logitech-options-plus.md` records how Logi Options+ communicates with the camera.

## License

MIT
