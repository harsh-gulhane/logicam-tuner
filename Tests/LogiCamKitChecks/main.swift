// Offline checks for LogiCamKit. Run with `swift run LogiCamKitChecks`; exits non-zero on failure.
@testable import LogiCamKit
import CoreVideo
import Foundation

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
    do {
        if try condition() { passed += 1; return }
        print("FAIL line \(line): \(message)")
    } catch {
        print("FAIL line \(line): \(message) threw \(error)")
    }
    failures += 1
}

func checkThrows<E: Error & Equatable>(_ expected: E?, _ message: String, line: Int = #line, _ body: () throws -> Void) {
    do {
        try body()
        print("FAIL line \(line): \(message) did not throw")
        failures += 1
    } catch let error as E where expected == nil || error == expected {
        passed += 1
    } catch {
        print("FAIL line \(line): \(message) threw unexpected \(error)")
        failures += 1
    }
}

func fixture(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    let hex = Array(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
}

// MARK: Real StreamCam descriptor (046d:0893, firmware 0x0317)

let streamcam = try fixture("streamcam-046d-0893-fw0317.hex")
let topology = try DescriptorParser.parse(configuration: streamcam)
check(topology.interfaceNumber == 0, "VC interface number")
check(topology.uvcVersion == 0x0100, "UVC version")
check(topology.cameraTerminal == .init(id: 1, controlBits: 0x22A2E), "camera terminal")
check(topology.processingUnits == [.init(id: 3, controlBits: 0x175B)], "processing unit")
check(topology.extensionUnits.map { "\($0.id) \($0.guid.uuidString) \($0.controlCount)" } == [
    "14 2C49D16A-32B8-4485-3EA8-643A152362F2 6",
    "6 23E49ED0-1178-4F31-AE52-D2FB8A8D3B48 14",
    "8 69678EE4-410F-40DB-A850-7420D7D8240E 8",
    "9 1F5D4CA9-DE11-4487-840D-50933C8EC8D1 18",
    "10 49E40215-F434-47FE-B158-0E885023E51B 11",
    "11 FFE52D21-8030-4E2C-82D9-F587D00540BD 4",
], "extension unit GUIDs in display byte order")
check(Camera.resolveControls(topology).map(\.id) == [
    "exposure_mode", "exposure_priority", "focus_auto", "exposure_time", "focus", "zoom", "pan", "tilt", "roll",
    "white_balance_auto", "brightness", "contrast", "saturation", "sharpness", "white_balance", "gain",
    "backlight_compensation", "power_line_frequency",
], "advertised standard controls")

// MARK: Malformed descriptors

checkThrows(DescriptorError?.none, "truncated descriptor") {
    _ = try DescriptorParser.parse(configuration: Array(streamcam.dropLast(3)))
}
checkThrows(DescriptorError.truncated(offset: 0), "zero-length descriptor") {
    _ = try DescriptorParser.parse(configuration: [0, 2, 0])
}
checkThrows(DescriptorError.noVideoControlInterface, "configuration without a VC interface") {
    // Configuration header followed by a mass-storage interface.
    _ = try DescriptorParser.parse(configuration: [9, 2, 18, 0, 1, 1, 0, 0x80, 50, 9, 4, 0, 0, 2, 0x08, 0x06, 0x50, 0])
}

// MARK: Wire values

let brightness = ControlCatalog.definition("brightness")!
check(WireCodec.decode([0xF6, 0xFF], brightness) == -10, "signed brightness")
check(WireCodec.decode([0x80, 0x00], brightness) == 128, "positive brightness")

let pan = ControlCatalog.definition("pan")!
let tilt = ControlCatalog.definition("tilt")!
var panTilt = [UInt8](repeating: 0, count: 8)
WireCodec.encode(-3600, into: &panTilt, tilt)
WireCodec.encode(7200, into: &panTilt, pan)
check(WireCodec.decode(panTilt, pan) == 7200 && WireCodec.decode(panTilt, tilt) == -3600, "pan/tilt fields round-trip")
check(panTilt == [0x20, 0x1C, 0, 0, 0xF0, 0xF1, 0xFF, 0xFF], "pan/tilt wire layout")

check(!ControlDefinition.isAutomatic(gate: "exposure_mode", value: 1), "manual exposure unlocks exposure time")
check(!ControlDefinition.isAutomatic(gate: "exposure_mode", value: 4), "shutter priority unlocks exposure time")
check(ControlDefinition.isAutomatic(gate: "exposure_mode", value: 8), "aperture priority locks exposure time")
check(ControlDefinition.isAutomatic(gate: "focus_auto", value: 1), "autofocus locks focus")
check(!ControlDefinition.isAutomatic(gate: "focus_auto", value: 0), "manual focus unlocks focus")

// MARK: Preset storage

let presetURL = FileManager.default.temporaryDirectory.appendingPathComponent("logicam-\(UUID()).json")
defer { try? FileManager.default.removeItem(at: presetURL) }
let store = PresetStore(url: presetURL)
let camA = CameraInfo(registryID: 1, locationID: 1, vendorID: 0x046D, productID: 0x0893, firmware: 0x317,
                      videoControlInterface: 0, name: "A", serial: "S1")
let camB = CameraInfo(registryID: 2, locationID: 2, vendorID: 0x046D, productID: 0x0893, firmware: 0x317,
                      videoControlInterface: 0, name: "B", serial: "S2")
try store.save(Preset(values: ["brightness": 120]), named: "Desk", for: camA)
try store.setStartupPreset("Desk", for: camA)
check(PresetStore(url: presetURL).presets(for: camA) == ["Desk": Preset(values: ["brightness": 120])], "preset persists")
check(PresetStore(url: presetURL).startupPreset(for: camA) == "Desk", "startup preset persists")
check(store.presets(for: camB).isEmpty, "presets are per camera")
try store.delete(named: "Desk", for: camA)
check(store.startupPreset(for: camA) == nil, "deleting a preset clears it as startup preset")

// MARK: Formatting

check(ShutterSpeed.label(units: 333) == "1/30 s", "shutter label at 30 fps")
check(ShutterSpeed.label(units: 2047) == "1/5 s", "shutter label at the StreamCam maximum")
check(ShutterSpeed.label(units: 10_000) == "1.0 s", "shutter label for long exposures")
check(ControlCatalog.format("zoom", 150) == "1.5×", "zoom label")

// MARK: Exposure allocation

let limits = ExposureLimits(time: 3...2047, gain: 0...255, maxTime: 333, maxGain: 255, flickerPeriod: 100)
let flickerSafe = ExposureController.setting(forEV: log2(250), limits)
check(flickerSafe.time == 200 && flickerSafe.gain > 0, "shutter snaps to whole mains periods, gain makes up the rest")
check(ExposureController.setting(forEV: log2(50), limits) == ExposureSetting(time: 50, gain: 0),
      "bright scenes use short shutter and no gain")
check(ExposureController.setting(forEV: log2(333) + 1, limits).time == 300, "shutter stops at the frame-rate limit")
check(ExposureController.brightest(limits) == ExposureSetting(time: 300, gain: 255), "brightest setting")
let capped = ExposureLimits(time: 3...2047, gain: 0...255, maxTime: 333, maxGain: 128, flickerPeriod: nil)
check(ExposureController.brightest(capped) == ExposureSetting(time: 333, gain: 128), "gain cap and no anti-flicker")

// MARK: Exposure feedback against a simulated camera

/// A camera whose real gain is half as strong as the controller assumes and whose tone curve
/// exaggerates exposure changes 1.8x, both seen on a real StreamCam in dim light.
func simulatedScene(_ s: ExposureSetting, light: Double) -> FrameStatistics {
    let exposure = light * Double(s.time) * (1 + Double(s.gain) / 64)
    let luminance = min(pow(exposure, 1.8), 1)
    return FrameStatistics(sceneLuminance: luminance, faceLuminance: nil, clippedFraction: 0,
                           neutralCast: nil, neutralFraction: 0, averageCast: .neutral)
}
func runExposure(light: Double, from start: ExposureSetting, steps: Int) -> (ExposureSetting, changes: [Int]) {
    var controller = ExposureController()
    var setting = start
    var changes: [Int] = []
    for step in 0..<steps {
        if let next = controller.update(simulatedScene(setting, light: light), current: setting, limits: limits) {
            setting = next
            changes.append(step)
        }
    }
    return (setting, changes)
}
// light chosen so that target brightness needs about 1/60 s and no gain.
let light = pow(ExposureController.sceneTarget, 1 / 1.8) / 166
let (settled, changes) = runExposure(light: light, from: ExposureSetting(time: 10, gain: 0), steps: 40)
let settledError = ExposureController().error(for: simulatedScene(settled, light: light))
check(abs(settledError) < ExposureController.startThreshold, "exposure converges from far too dark (error \(settledError))")
check((changes.last ?? 0) < 15, "exposure settles within 15 analysed frames (last change at \(changes.last ?? -1))")
// The target (about 166 units) falls between two flicker-safe shutter times; this used to cycle.
let (fromBright, brightChanges) = runExposure(light: light, from: ExposureSetting(time: 2047, gain: 255), steps: 40)
check(abs(ExposureController().error(for: simulatedScene(fromBright, light: light))) < ExposureController.startThreshold
      && (brightChanges.last ?? 0) < 15, "exposure converges from far too bright without cycling")
// A manual shutter from before Smart Auto, beyond the frame-rate limit, is replaced even for a small correction.
var inherited = ExposureController()
let slow = ExposureSetting(time: 2047, gain: 48)
let slightlyBright = FrameStatistics(sceneLuminance: 0.16 * pow(2, 0.4), faceLuminance: nil, clippedFraction: 0,
                                     neutralCast: nil, neutralFraction: 0, averageCast: .neutral)
check(inherited.update(slightlyBright, current: slow, limits: limits).map { $0.time <= 333 && $0.time % 100 == 0 } == true,
      "an out-of-limits shutter time is re-split into a flicker-safe one")
let onTarget = FrameStatistics(sceneLuminance: 0.16, faceLuminance: nil, clippedFraction: 0,
                               neutralCast: nil, neutralFraction: 0, averageCast: .neutral)
var fresh = ExposureController()
check(fresh.update(onTarget, current: slow, limits: limits).map { $0.time <= 333 } == true,
      "an out-of-limits setting is replaced even when brightness is on target")
let (_, darkChanges) = runExposure(light: light / 40, from: ExposureSetting(time: 10, gain: 0), steps: 40)
check((darkChanges.last ?? 0) < 20, "exposure stops changing at its limit in the dark")

var faceMeter = ExposureController()
let backlit = FrameStatistics(sceneLuminance: 0.16, faceLuminance: 0.04, clippedFraction: 0.1,
                              neutralCast: nil, neutralFraction: 0, averageCast: .neutral)
check(faceMeter.error(for: backlit) > 0.5, "a dark face against a bright scene brightens exposure")
faceMeter.facePriority = false
check(faceMeter.error(for: backlit) < 0, "without face priority a clipped scene darkens exposure")
faceMeter.bias = 1
check(abs(faceMeter.error(for: FrameStatistics(sceneLuminance: 0.16, faceLuminance: nil, clippedFraction: 0,
                                                neutralCast: nil, neutralFraction: 0, averageCast: .neutral)) - 1) < 1e-9,
      "exposure compensation shifts the target")

// MARK: White balance feedback against a simulated camera

/// Neutral surfaces render warm when the camera's temperature is above the light's (3400 K here).
func simulatedNeutral(kelvin: Int) -> FrameStatistics {
    let warmth = (1e6 / 3400 - 1e6 / Double(kelvin)) / 150
    return FrameStatistics(sceneLuminance: 0.16, faceLuminance: nil, clippedFraction: 0,
                           neutralCast: Chroma(warmth: warmth, tint: 0), neutralFraction: 0.3,
                           averageCast: Chroma(warmth: warmth, tint: 0))
}
var wb = WhiteBalanceController()
var kelvin = 6500
var lastWBChange = -1
for step in 0..<40 {
    if let next = wb.update(simulatedNeutral(kelvin: kelvin), currentKelvin: kelvin, range: 2000...7500) {
        kelvin = next
        lastWBChange = step
    }
}
check(abs(kelvin - 3400) < 200, "white balance converges to the light's temperature (got \(kelvin) K)")
check(lastWBChange < 25, "white balance settles (last change at \(lastWBChange))")
let noNeutrals = FrameStatistics(sceneLuminance: 0.16, faceLuminance: nil, clippedFraction: 0, neutralCast: nil,
                                 neutralFraction: 0.01, averageCast: Chroma(warmth: 0.5, tint: 0))
check(wb.update(noNeutrals, currentKelvin: 5000, range: 2000...7500) == nil, "white balance holds without neutral pixels")
check(wb.searchCenter.warmth > 0, "the neutral search follows the frame's cast")

// MARK: Frame analysis

func frame(width: Int = 64, height: Int = 36, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            bytes[(y * width + x) * 4] = b
            bytes[(y * width + x) * 4 + 1] = g
            bytes[(y * width + x) * 4 + 2] = r
        }
    }
    return bytes
}
func analyze(_ bytes: [UInt8], faces: [CGRect] = []) -> FrameStatistics {
    bytes.withUnsafeBytes { FrameAnalyzer.analyze(bgra: $0, width: 64, height: 36, bytesPerRow: 256, faces: faces) }
}
let grey = analyze(frame { _, _ in (128, 128, 128) })
check(abs(grey.sceneLuminance - FrameAnalyzer.linear[128]) < 0.002, "grey frame luminance")
check(grey.neutralCast.map { abs($0.warmth) < 1e-6 && abs($0.tint) < 1e-6 } == true, "grey frame is neutral")
check(grey.faceLuminance == nil && grey.clippedFraction == 0, "grey frame has no face or clipping")
let amber = analyze(frame { _, _ in (180, 128, 90) })
check(amber.neutralCast == nil && amber.averageCast.warmth > 0.5, "strong amber cast is found by the average, not as neutral")
let face = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
let darkFace = analyze(frame { x, y in face.contains(CGPoint(x: (Double(x) + 0.5) / 64, y: (Double(y) + 0.5) / 36)) ? (40, 40, 40) : (128, 128, 128) },
                       faces: [face])
check(darkFace.faceLuminance.map { $0 < 0.05 } == true && darkFace.sceneLuminance > 0.05, "face luminance is measured separately")
let clipped = analyze(frame { _, _ in (255, 255, 255) })
check(clipped.clippedFraction > 0.99, "white frame is clipped")

/// A camera-native 4:2:0 video-range BT.709 frame of one colour.
func ycbcrFrame(_ r: Double, _ g: Double, _ b: Double) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
    let pb = buffer!
    let yp = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let y = UInt8((16 + yp * 219 / 255).rounded())
    let cb = UInt8((128 + (b - yp) / 1.8556 * 224 / 255).rounded())
    let cr = UInt8((128 + (r - yp) / 1.5748 * 224 / 255).rounded())
    CVPixelBufferLockBaseAddress(pb, [])
    let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<36 { for col in 0..<64 { luma[row * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + col] = y } }
    for row in 0..<18 {
        for col in 0..<32 {
            chroma[row * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + col * 2] = cb
            chroma[row * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + col * 2 + 1] = cr
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}
let ycbcrGrey = FrameAnalyzer.analyze(ycbcrFrame(128, 128, 128))
check(ycbcrGrey.map { abs($0.sceneLuminance - grey.sceneLuminance) < 0.005 && abs($0.neutralCast?.warmth ?? 1) < 0.02 } == true,
      "native YCbCr frames measure like BGRA (grey)")
let ycbcrAmber = FrameAnalyzer.analyze(ycbcrFrame(180, 128, 90))
check(ycbcrAmber.map { abs($0.averageCast.warmth - amber.averageCast.warmth) < 0.05 } == true,
      "native YCbCr frames measure like BGRA (amber)")

// MARK: Choice bounds

let plfControl = CameraControl(definition: ControlCatalog.definition("power_line_frequency")!, unitID: 3)
let plf = ControlState(control: plfControl, current: 2, minimum: 1, maximum: 2, resolution: nil, defaultValue: 2,
                       info: [.get, .set], lockedByAutomaticMode: false)
check(plf.choices.map(\.label) == ["50 Hz", "60 Hz"], "anti-flicker offers only what the camera's range allows")
check(CameraError.io(operation: "set Anti-flicker", code: Int32(bitPattern: 0xE000_404F)).description
      == "Couldn't set Anti-flicker: the camera rejected the request (0xe000404f)", "readable stall error")

// MARK: Camera users

check(CameraUsers.outermostApp("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Alerts).app/Contents/MacOS/x")
      == "/Applications/Google Chrome.app", "a helper belongs to its outermost app")
check(CameraUsers.outermostApp("/System/Applications/FaceTime.app") == "/System/Applications/FaceTime.app", "an app bundle path")
check(CameraUsers.outermostApp("/usr/libexec/avconferenced") == nil, "a daemon has no app bundle")
check(CameraUsers.daemonOwners["avconferenced"]?.name == "FaceTime", "FaceTime's conferencing daemon maps to FaceTime")

// MARK: Frame metadata

// Values as the MacBook Pro (M5) camera attached them under "MetadataDictionary".
let reportedMetadata = FrameMetadata(["ExposureTime": NSNumber(value: 0.016664), "ISOSpeedRating": NSNumber(value: 349.29),
                                      "CCT": NSNumber(value: 3103), "LuxLevel": NSNumber(value: 318), "AGC": NSNumber(value: 2048)])
check(reportedMetadata == FrameMetadata(exposureTime: 0.016664, iso: 349.29, colorTemperature: 3103, lux: 318),
      "Apple camera frame metadata")
check(FrameMetadata(["AGC": NSNumber(value: 2048), "ExposureTime": NSNumber(value: -1)]) == nil, "no known or valid values")
check(FrameMetadata(["CCT": "3100"]) == nil, "non-numeric values are ignored")
check(ShutterSpeed.label(seconds: 0.016664) == "1/60 s" && ShutterSpeed.label(units: 333) == "1/30 s", "shutter labels")

// MARK: Following the camera in use

let streamCam = VideoCamera(id: "usb-1", name: "Logitech StreamCam", uvc: camA, isBuiltIn: false)
let builtIn = VideoCamera(id: "mac", name: "MacBook Pro Camera", uvc: nil, isBuiltIn: true)
let iPhone = VideoCamera(id: "phone", name: "iPhone Camera", uvc: nil, isBuiltIn: false)
check(VideoCamera.follow(selected: streamCam, selectedInUse: false, busy: [builtIn], chosen: streamCam) == builtIn,
      "a call on the Mac's camera is followed")
check(VideoCamera.follow(selected: builtIn, selectedInUse: true, busy: [], chosen: streamCam) == nil, "stay while that call lasts")
check(VideoCamera.follow(selected: builtIn, selectedInUse: false, busy: [], chosen: streamCam) == streamCam,
      "back to the chosen camera after the call")
check(VideoCamera.follow(selected: streamCam, selectedInUse: true, busy: [builtIn], chosen: streamCam) == nil,
      "a StreamCam call keeps priority over another camera's")
check(VideoCamera.follow(selected: builtIn, selectedInUse: true, busy: [streamCam], chosen: builtIn) == streamCam,
      "a StreamCam call takes over from a camera without controls")
check(VideoCamera.follow(selected: iPhone, selectedInUse: false, busy: [builtIn, streamCam], chosen: iPhone) == streamCam,
      "UVC cameras first when several are in use")
check(VideoCamera.follow(selected: streamCam, selectedInUse: false, busy: [], chosen: streamCam) == nil, "idle on the chosen camera")

// MARK: Smart Auto settings

let decoded = try JSONDecoder().decode(SmartAutoSettings.self, from: Data("{\"exposure\": true}".utf8))
check(decoded.exposure && !decoded.whiteBalance && decoded.minimumFrameRate == 15 && decoded.maxGain == 1,
      "older or partial settings decode with defaults")
check(decoded.ownedControls == ["exposure_mode", "exposure_time", "gain", "exposure_priority"], "exposure-owned controls")
try store.setSmartAuto(decoded, for: camA)
check(PresetStore(url: presetURL).smartAuto(for: camA) == decoded && store.smartAuto(for: camB) == SmartAutoSettings(),
      "Smart Auto settings persist per camera")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
