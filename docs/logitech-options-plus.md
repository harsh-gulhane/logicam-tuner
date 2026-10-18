# How Logi Options+ controls a webcam (macOS)

Notes from inspecting Logi Options+ 2.9.994631 on macOS 27.0.1 with a Logitech
StreamCam (046d:0893, firmware 0x0317). Each point is marked as observed (seen
directly), derived (read from shipped code or data) or inferred.

## Architecture

- **Derived.** `/Applications/logioptionsplus.app` is an Electron UI. Device work is done
  by a separate native process, `logioptionsplus_agent`, launched by launchd from
  `/Library/Application Support/Logitech.localized/LogiOptionsPlus/`.
- **Derived.** The UI's main process connects to the agent over a Unix socket at
  `/tmp/logitech_kiros_agent-<md5(username)>`.
- **Derived.** Frames are `[u32 LE total][u32 BE n]["json"][u32 BE m][m bytes of JSON]`,
  where total = n + m + 8. Messages look like `{"msg_id", "verb", "path", "payload"}`,
  with verbs GET, SET, BROADCAST, REMOVE, SUBSCRIBE, UNSUBSCRIBE and OPTIONS
  (protobuf `logi.protocol.Message`, carried as JSON).
- **Derived.** Webcam routes include `/uvc/<id>/capabilities`, `video/settings`,
  `camera/settings`, `focus/settings`, `crop/settings`, `auto_framing`, `rightsight`,
  `showmode/settings`, `microphone/settings` and `streaming_status`.
- **Observed.** A read-only GET from an unsigned client connected but got no reply.
  **Inferred.** The agent logs each client's PID, path and signing status and contains a
  Logitech code-signing requirement, so it likely ignores clients not signed by Logitech.
  LogiCam Tuner therefore does not use this socket.

## Talking to the camera

- **Observed.** `ioreg` shows `logioptionsplus_agent` holding an
  `AppleUSBHostInterfaceUserClient` on the StreamCam's interface 0, the UVC Video
  Control interface (class 0x0E, subclass 0x01). Apple's `UVCAssistant` holds the same
  interface for streaming.
- **Inferred.** The agent therefore sends UVC class control requests through IOKit,
  the same path LogiCam Tuner uses.
- **Observed.** The StreamCam advertises a camera terminal (unit 1), a processing unit
  (unit 3) and six extension units:

  | Unit | GUID | Controls | Notes |
  | --- | --- | --- | --- |
  | 6 | 23E49ED0-1178-4F31-AE52-D2FB8A8D3B48 | 14 | GUID also present in the agent binary |
  | 8 | 69678EE4-410F-40DB-A850-7420D7D8240E | 8 | Publicly known as Logitech device information |
  | 9 | 1F5D4CA9-DE11-4487-840D-50933C8EC8D1 | 18 | Publicly known as Logitech test/debug |
  | 10 | 49E40215-F434-47FE-B158-0E885023E51B | 11 | Publicly known as Logitech video pipe |
  | 11 | FFE52D21-8030-4E2C-82D9-F587D00540BD | 4 | Publicly known as Logitech peripheral control |
  | 14 | 2C49D16A-32B8-4485-3EA8-643A152362F2 | 6 | Not present in the agent's GUID strings |

- **Unknown.** Which extension-unit selectors implement auto-framing or Show Mode.
  Finding out would mean decompiling the agent's `logi::uvc` units or capturing USB
  traffic while toggling those features in Options+.

## Controls Options+ offers for the StreamCam

- **Derived.** `card_presets/card_presets_streamcam.json` in the Options+ install defines the
  StreamCam's settings groups: camera (exposure auto/manual, priority `EXPOSURE` or
  `FRAME_RATE`, gain, `hdr`), video (brightness, contrast, saturation, sharpness, white balance
  auto/manual), crop (zoom, pan, tilt), focus (auto/manual) and microphone.
- **Derived.** The UI labels gain as "ISO" and exposure as "Shutter speed", and maps the priority
  to a "low light compensation" switch.
- **Derived.** The agent's `logi::uvc::Device` has methods for every standard UVC control plus
  vendor features (`fov`, `rightsight`, `auto_framing`, `eis`, `tint`, `vibrance`,
  `white_balance_compensation`, `exposure_compensation`, ...), but no `hdr` method. It does have
  `backlight_compensation` with a `BacklightCompensation` type.
- **Inferred.** HDR on the StreamCam is the UVC backlight compensation control, which the camera
  reports as a 0...1 switch. LogiCam Tuner labels it "HDR (backlight compensation)".

## Camera behaviour measured with `logicam auto --watch`

- **Observed.** White-balance temperature changes the image as expected: average warmth rose from
  -0.39 at 2800 K to +0.92 at 6500 K. One unit of warmth corresponded to 90-200 mired.
- **Observed.** Gain 0 is nearly black in dim light, and gain adds less brightness per step
  as it rises. Doubling the shutter time raised measured brightness by 1.6-2.3x the
  expected amount, because of the camera's tone curve.
- **Observed.** In a dim room, the camera's own auto exposure chose 1/25 s at full gain. Its auto
  white balance had started near 5230 K, which rendered white surfaces amber, and was still
  drifting after five seconds.
- **Observed.** `AVCaptureDevice.isInUseByAnotherApplication` stayed false while other processes
  streamed from the camera; CoreMediaIO's `kCMIODevicePropertyDeviceIsRunningSomewhere` reported it.

## Behaviour seen while testing LogiCam Tuner

- **Observed.** Standard control writes succeed while Options+ is running, and values
  persisted for at least 12 s while the camera was idle.
- **Unknown.** Whether Options+ reapplies its settings when a stream starts. The agent has
  a `/uvc/<id>/stream_started` route and a priority enum for who last set framing
  (`DEFAULT_OPTIONS_PLUS`, `USER_APPLIED`, …), which suggests it may.
