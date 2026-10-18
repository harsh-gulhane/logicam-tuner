import CUSBTransport
import Foundation

public enum CameraError: Error, Equatable, CustomStringConvertible {
    case io(operation: String, code: Int32)
    case descriptor(DescriptorError)
    case unsupported(String)
    case outOfRange(control: String, value: Int, min: Int, max: Int)
    case invalidChoice(control: String, value: Int)

    public var description: String {
        switch self {
        case let .io(operation, code):
            "\(operation) failed: \(String(format: "0x%08x", UInt32(bitPattern: code))) \(ioReturnName(code))"
        case let .descriptor(error): error.description
        case let .unsupported(id): "control \(id) is not supported by this camera"
        case let .outOfRange(id, value, min, max): "\(id)=\(value) is outside \(min)...\(max)"
        case let .invalidChoice(id, value): "\(value) is not a supported choice for \(id)"
        }
    }
}

private func ioReturnName(_ code: Int32) -> String {
    switch UInt32(bitPattern: code) {
    case 0xE000_4051: "(pipe stalled: the camera rejected the request)"
    case 0xE000_02C0: "(no device)"
    case 0xE000_02C5: "(exclusive access)"
    case 0xE000_02CD: "(not open)"
    case 0xE000_02C7: "(unsupported)"
    case 0xE000_02D6: "(timeout)"
    default: ""
    }
}

/// Identity of an attached UVC camera.
public struct CameraInfo: Hashable, Sendable, Identifiable {
    public let registryID: UInt64
    public let locationID: UInt32
    public let vendorID: UInt16
    public let productID: UInt16
    public let firmware: UInt16
    public let videoControlInterface: UInt8
    public let name: String
    public let serial: String

    public var id: UInt64 { registryID }
    public var isLogitech: Bool { vendorID == 0x046D }
    /// Stable across replugging; used to key presets.
    public var persistentKey: String {
        String(format: "%04x:%04x:", vendorID, productID) + (serial.isEmpty ? String(format: "loc%08x", locationID) : serial)
    }
}

/// A control the camera advertises, bound to the unit that implements it.
public struct CameraControl: Equatable, Sendable, Identifiable {
    public let definition: ControlDefinition
    public let unitID: UInt8
    public var id: String { definition.id }
}

/// GET_INFO capability bits (UVC 1.5 table 4-3).
public struct ControlInfo: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let get = ControlInfo(rawValue: 1 << 0)
    public static let set = ControlInfo(rawValue: 1 << 1)
    public static let disabledByAutomaticMode = ControlInfo(rawValue: 1 << 2)
    public static let autoUpdate = ControlInfo(rawValue: 1 << 3)
    public static let asynchronous = ControlInfo(rawValue: 1 << 4)
}

/// A snapshot of one control. Range attributes are nil when the camera did not report them.
public struct ControlState: Equatable, Sendable {
    public let control: CameraControl
    public let current: Int
    public let minimum: Int?
    public let maximum: Int?
    public let resolution: Int?
    public let defaultValue: Int?
    public let info: ControlInfo
    /// True when the gating auto control is on. Many cameras report GET_INFO's "disabled by automatic
    /// mode" bit statically, so LogiCam Tuner derives this from the gating control's current value instead.
    public let lockedByAutomaticMode: Bool

    public var isWritable: Bool { info.contains(.set) && !lockedByAutomaticMode }

    /// The same control with a newer current value, e.g. one LogiCam Tuner just wrote.
    public func with(current: Int) -> ControlState {
        ControlState(control: control, current: current, minimum: minimum, maximum: maximum, resolution: resolution,
                     defaultValue: defaultValue, info: info, lockedByAutomaticMode: lockedByAutomaticMode)
    }

    /// Clamps a value into the reported range.
    public func clamped(_ value: Int) -> Int {
        min(max(value, minimum ?? value), maximum ?? value)
    }

    /// Choices the camera accepts, for choice controls.
    public var choices: [ControlKind.Choice] {
        guard case let .choice(all, fromResolution) = control.definition.kind else { return [] }
        guard fromResolution, let mask = resolution else { return all }
        return all.filter { mask & $0.value != 0 }
    }
}

public final class Camera: @unchecked Sendable {
    public let info: CameraInfo
    public let topology: VideoControlTopology
    public let controls: [CameraControl]
    /// The raw configuration descriptor the topology was parsed from.
    public let configurationDescriptor: [UInt8]

    private enum Request: UInt8 {
        case setCurrent = 0x01, getCurrent = 0x81, getMinimum = 0x82, getMaximum = 0x83
        case getResolution = 0x84, getInfo = 0x86, getDefault = 0x87
    }

    public static func list() -> [CameraInfo] {
        var buffer = [cusb_camera](repeating: cusb_camera(), count: 32)
        let total = Int(cusb_list_cameras(&buffer, Int32(buffer.count)))
        return buffer.prefix(min(total, buffer.count)).map { raw in
            var raw = raw
            let name = withUnsafeBytes(of: &raw.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let serial = withUnsafeBytes(of: &raw.serial) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return CameraInfo(registryID: raw.registry_id, locationID: raw.location_id, vendorID: raw.vendor_id,
                              productID: raw.product_id, firmware: raw.bcd_device,
                              videoControlInterface: raw.vc_interface_number, name: name, serial: serial)
        }
    }

    public init(_ info: CameraInfo) throws {
        self.info = info
        var buffer = [UInt8](repeating: 0, count: 4096)
        var length: UInt32 = 0
        var status = cusb_copy_config_descriptor(info.registryID, &buffer, UInt32(buffer.count), &length)
        if status == Int32(bitPattern: 0xE000_02E8), length > 0 { // kIOReturnOverrun: retry with the reported size
            buffer = [UInt8](repeating: 0, count: Int(length))
            status = cusb_copy_config_descriptor(info.registryID, &buffer, UInt32(buffer.count), &length)
        }
        guard status == 0 else { throw CameraError.io(operation: "read configuration descriptor", code: status) }
        configurationDescriptor = Array(buffer.prefix(Int(length)))
        do {
            topology = try DescriptorParser.parse(configuration: configurationDescriptor)
        } catch let error as DescriptorError {
            throw CameraError.descriptor(error)
        }
        controls = Self.resolveControls(topology)
    }

    static func resolveControls(_ topology: VideoControlTopology) -> [CameraControl] {
        ControlCatalog.all.compactMap { definition in
            let unit: VideoControlTopology.Unit? = switch definition.unit {
            case .cameraTerminal: topology.cameraTerminal
            case .processingUnit: topology.processingUnits.first { $0.controlBits & (1 << UInt64(definition.bit)) != 0 }
            }
            guard let unit, unit.controlBits & (1 << UInt64(definition.bit)) != 0 else { return nil }
            return CameraControl(definition: definition, unitID: unit.id)
        }
    }

    public func control(_ id: String) throws -> CameraControl {
        guard let control = controls.first(where: { $0.id == id }) else { throw CameraError.unsupported(id) }
        return control
    }

    /// Reads current value, range, default and capability flags.
    public func read(_ control: CameraControl) throws -> ControlState {
        let d = control.definition
        let infoBytes = try transfer(control, .getInfo, length: 1)
        let current = WireCodec.decode(try transfer(control, .getCurrent, length: d.length), d)
        let optional = { (request: Request) -> Int? in
            (try? self.transfer(control, request, length: d.length)).map { WireCodec.decode($0, d) }
        }
        let isRange = d.kind == .range
        let resolution: Int? = switch d.kind {
        case .choice(_, supportedFromResolution: true): (try? transfer(control, .getResolution, length: d.length)).map { Int($0[0]) }
        case .range: optional(.getResolution)
        default: nil
        }
        return ControlState(control: control, current: current,
                            minimum: isRange ? optional(.getMinimum) : nil,
                            maximum: isRange ? optional(.getMaximum) : nil,
                            resolution: resolution, defaultValue: optional(.getDefault),
                            info: ControlInfo(rawValue: infoBytes.first ?? 0),
                            lockedByAutomaticMode: try isLocked(d))
    }

    public func read(_ id: String) throws -> ControlState { try read(control(id)) }

    /// Current values only (one GET_CUR each), for cheap live polling. Unsupported or failing controls are omitted.
    public func currentValues(_ ids: [String]) -> [String: Int] {
        ids.reduce(into: [:]) { values, id in
            guard let control = try? control(id),
                  let bytes = try? transfer(control, .getCurrent, length: control.definition.length) else { return }
            values[id] = WireCodec.decode(bytes, control.definition)
        }
    }

    private func isLocked(_ d: ControlDefinition) throws -> Bool {
        guard let gateID = d.automaticControlID, let gate = controls.first(where: { $0.id == gateID }) else { return false }
        let value = WireCodec.decode(try transfer(gate, .getCurrent, length: gate.definition.length), gate.definition)
        return ControlDefinition.isAutomatic(gate: gateID, value: value)
    }

    /// Writes a value after validating it against the camera-reported range or choices.
    public func write(_ control: CameraControl, value: Int) throws {
        let d = control.definition
        let state = try read(control)
        switch d.kind {
        case .range:
            if let lo = state.minimum, let hi = state.maximum, !(lo...hi).contains(value) {
                throw CameraError.outOfRange(control: d.id, value: value, min: lo, max: hi)
            }
        case .toggle:
            guard value == 0 || value == 1 else { throw CameraError.invalidChoice(control: d.id, value: value) }
        case .choice:
            guard state.choices.contains(where: { $0.value == value }) else {
                throw CameraError.invalidChoice(control: d.id, value: value)
            }
        }
        try setCurrent(control, value: value)
    }

    /// Writes without re-reading the range, for callers that already validated against a recent `ControlState`.
    public func setCurrent(_ control: CameraControl, value: Int) throws {
        let d = control.definition
        // Compound controls are written whole, so start from the current wire value.
        var bytes = d.fieldSize == d.length ? [UInt8](repeating: 0, count: d.length)
            : try transfer(control, .getCurrent, length: d.length)
        WireCodec.encode(value, into: &bytes, d)
        _ = try transfer(control, .setCurrent, length: d.length, payload: bytes)
    }

    public func write(_ id: String, value: Int) throws { try write(control(id), value: value) }

    /// Reads every supported control, skipping ones the camera refuses to report.
    public func readAll() -> [ControlState] { controls.compactMap { try? read($0) } }

    // MARK: Wire

    private func transfer(_ control: CameraControl, _ request: Request, length: Int, payload: [UInt8]? = nil) throws -> [UInt8] {
        var bytes = payload ?? [UInt8](repeating: 0, count: length)
        var transferred: UInt32 = 0
        var path = CUSB_PATH_NONE
        let isSet = request == .setCurrent
        let index = UInt16(control.unitID) << 8 | UInt16(info.videoControlInterface)
        let status = bytes.withUnsafeMutableBytes { buffer in
            cusb_control(info.registryID, info.videoControlInterface, isSet ? 0x21 : 0xA1, request.rawValue,
                         UInt16(control.definition.selector) << 8, index, buffer.baseAddress, UInt16(length),
                         &transferred, &path)
        }
        guard status == 0 else {
            throw CameraError.io(operation: "\(request) \(control.definition.id)", code: status)
        }
        return isSet ? bytes : Array(bytes.prefix(Int(transferred)))
    }
}

/// Little-endian UVC value encoding, including one field of a compound control.
enum WireCodec {
    static func decode(_ bytes: [UInt8], _ d: ControlDefinition) -> Int {
        var raw: UInt64 = 0
        for i in 0..<d.fieldSize where d.fieldOffset + i < bytes.count {
            raw |= UInt64(bytes[d.fieldOffset + i]) << (8 * UInt64(i))
        }
        guard d.signed else { return Int(raw) }
        let shift = UInt64(64 - 8 * d.fieldSize)
        return Int(Int64(bitPattern: raw << shift) >> Int64(shift))
    }

    static func encode(_ value: Int, into bytes: inout [UInt8], _ d: ControlDefinition) {
        if bytes.count < d.length { bytes += [UInt8](repeating: 0, count: d.length - bytes.count) }
        let raw = UInt64(bitPattern: Int64(value))
        for i in 0..<d.fieldSize { bytes[d.fieldOffset + i] = UInt8(truncatingIfNeeded: raw >> (8 * UInt64(i))) }
    }
}
