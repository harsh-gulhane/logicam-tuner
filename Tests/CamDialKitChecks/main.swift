// Offline checks for CamDialKit. Run with `swift run CamDialKitChecks`; exits non-zero on failure.
@testable import CamDialKit
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

let presetURL = FileManager.default.temporaryDirectory.appendingPathComponent("camdial-\(UUID()).json")
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

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
