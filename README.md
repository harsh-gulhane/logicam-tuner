# LogiCam Tuner

**Unofficial Mac app for the Logitech StreamCam** — every camera setting Logi Options+ offers,
smarter auto exposure and white balance, a sharp live preview and a live stream overlay. Built and
tested on the StreamCam; other Logitech webcams (Brio, C920, C922…) and most USB (UVC) webcams should
work too, but are untested so far.

> LogiCam Tuner is an independent, community project. It is not made, affiliated with or endorsed by
> Logitech. Logitech, Logi and StreamCam are trademarks of Logitech.

LogiCam Tuner talks to the camera directly with standard USB Video Class (UVC) control requests, the
same mechanism Logitech's own agent uses. It does not need Logi Options+, Logi Tune, a kernel
extension or a driver.

## Controls

| Options+ name | LogiCam Tuner | UVC control |
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

## The app

The main window shows a large live preview beside every control, so each change is visible as you
make it. A readout on the preview shows the current shutter speed, ISO and white balance. The
preview runs at 1080p and 30 or 60 fps, shows the measured frame rate, can be mirrored like a
video-call self-view, and it stops (camera light off) when the
window is closed, minimised or hidden.

## Stream overlay

A small floating panel shows, while any app uses the camera:

- which apps are using it (e.g. "Google Chrome", "FaceTime", "WhatsApp"),
- the resolution, configured frame rate and the frame rate actually delivered, and the pixel format,
- exposure (mode, shutter, ISO), white balance, focus, brightness, zoom, HDR, anti-flicker and low-light boost,
- Smart Auto's status and how long the camera has been on.

It stays above other windows, appears on every Space and over full-screen apps, never takes focus
from the call, and can be dragged anywhere. Choose Off / While an app uses the camera / Always in the
App section or the menu-bar panel. The main window keeps a list of recent camera sessions so you can
compare how Meet, WhatsApp and FaceTime configure the camera; `logicam who` prints the same from the
terminal.

macOS has no public API that names the apps using a camera. LogiCam Tuner reports the apps that are
capturing the microphone while the camera runs, as call apps do, and otherwise the frontmost app
known to use cameras (marked with "?"). An app using the camera with its microphone fully off is
shown as "Unknown app". Resolution and frame rate are the camera's: apps may scale the picture further.

A menu-bar icon gives quick access to the same controls. Closing the window keeps LogiCam Tuner running
there, so Smart Auto keeps working; quit from the menu-bar icon.

Also: presets per camera (one can apply automatically whenever the camera connects) and Open at login.

## Smart Auto

Pick **Smart** for exposure, white balance or both. While any app (Zoom, Meet, FaceTime, OBS…) is
using the camera, LogiCam Tuner looks at a small copy of the video on your Mac and steers the camera's
manual controls itself:

- **Faces first.** Exposure meters detected faces, blended with the scene, so a bright window behind
  you no longer leaves your face dark.
- **No breathing.** Exposure only starts correcting at a clearly visible error (0.25 EV) and stops close
  to target; white balance has the same kind of hysteresis. The picture settles and stays put.
- **White balance from neutral surfaces.** Only near-grey, well-exposed pixels outside faces count, so a
  coloured shirt or wall does not pull the colour. With too few neutral pixels, it holds the current
  setting instead of guessing.
- **Clean and flicker-free.** Shutter time is spent before gain, and snapped to whole mains periods
  so lights do not band. You choose whether low light may lower the frame rate (keep it, or down to 30, 15 or 7.5 fps)
  and the highest ISO.
- **Your taste.** Exposure compensation (±2 EV) and a warmth slider.

On a StreamCam in a dim room, the camera's own auto exposure chose 1/25 s at full gain and its auto
white balance left whites amber (5230 K) and drifted for seconds. Smart Auto settled at 1/17 s,
which keeps 15 fps, and neutral whites at about 3400 K within roughly two seconds. Measured with
`logicam auto --watch` on one camera and one room; your results will differ.

Smart Auto never turns the camera on by itself: it runs only while another app is streaming (or the
preview is open). Video is analysed in memory and never recorded or sent anywhere. When LogiCam Tuner
quits, the camera's own automatics are switched back on; Smart Auto resumes at the next launch.

## Install

Requires macOS 14 or later and Swift 5.10+ (Xcode or the Command Line Tools).

```sh
./scripts/build-app.sh          # builds "build/LogiCam Tuner.app" (universal, ad-hoc signed)
open "build/LogiCam Tuner.app"
```

Copy `build/LogiCam Tuner.app` to `/Applications` to keep it. Because the build is ad-hoc signed,
another Mac will warn on first launch; right-click → Open. macOS asks for camera access the first
time Smart Auto or the preview needs video.

## CLI

```sh
swift build -c release --product logicam
LOGICAM=$(swift build -c release --show-bin-path)/logicam
$LOGICAM list
$LOGICAM describe
$LOGICAM get
$LOGICAM set brightness=140 white_balance_auto=off white_balance=4500
$LOGICAM set exposure_mode=auto
$LOGICAM preset save desk
$LOGICAM preset apply desk
$LOGICAM reset
$LOGICAM auto                    # Smart Auto until Ctrl-C (turns the camera on)
$LOGICAM auto exposure --bias -0.3 --min-fps 15
$LOGICAM auto --watch            # print measurements only; change nothing
```

Use `--camera <index|serial>` when several cameras are attached and `--json` for scripting.

## Notes

- **Logi Options+ / Logi Tune running at the same time.** They can reapply their own saved settings.
  In testing, values LogiCam Tuner set (including Smart Auto's) stayed in place with Options+ running.
- **Detecting other apps.** LogiCam Tuner asks CoreMediaIO whether the camera is streaming. While Smart Auto
  is streaming itself, it pauses for about a second every 10 seconds to check whether the other app
  is still there. (`AVCaptureDevice.isInUseByAnotherApplication` did not report other apps on macOS 27.)
- **"Disabled by auto mode".** Many cameras (including the StreamCam) report UVC's "disabled by
  automatic mode" flag permanently, so LogiCam Tuner decides whether a control is locked from the current
  value of its auto control instead.
- **Logitech-only features.** Auto-framing (RightSight) and Show Mode use vendor extension units whose
  protocol is not public. LogiCam Tuner lists those units but does not drive them. On the StreamCam, Options+
  offers no other image controls.
- **Diagnostics.** `~/Library/Logs/LogiCamTuner.log` (also `log stream --predicate 'subsystem == "io.github.logicamtuner"'`)
  records when capture starts and stops, each stream's format and measured frame rate, and session summaries.
- **Preview in the background.** The preview pauses while LogiCam Tuner is not the active app: the call app
  shows its own picture, and LogiCam Tuner can only tell which other apps use the camera while it is not
  streaming itself.

## Tested hardware

| Camera | USB ID | Firmware | Result |
| --- | --- | --- | --- |
| Logitech StreamCam | 046d:0893 | 0x0317 | All 18 advertised standard controls and Smart Auto, macOS 27.0.1 |

Reports for other cameras are welcome: include `logicam list` and `logicam describe` output.

## Coming from CamDial

This project was called CamDial. On first launch, presets, Smart Auto settings, session history and
preferences are moved over automatically. Because the app has a new identity, macOS asks for camera
access again, and "Open at login" needs switching on again.

## Development

```sh
swift build
swift run LogiCamKitChecks      # offline checks, including a real StreamCam descriptor fixture
```

The checks run the exposure and white-balance controllers against simulated cameras whose behaviour
(weak gain, exaggerated tone curve, flicker-safe shutter steps) was measured on a real StreamCam.

`docs/logitech-options-plus.md` records how Logi Options+ communicates with the camera.

## License

MIT
