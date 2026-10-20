import Foundation

/// The UVC entity that owns a control.
public enum ControlUnit: String, Codable, Sendable {
    case cameraTerminal
    case processingUnit
}

/// How a control's value should be presented and validated.
public enum ControlKind: Equatable, Sendable {
    case range
    case toggle
    /// Fixed choices. When `supportedFromResolution` is true, GET_RES returns a bitmap of the valid choices.
    case choice([Choice], supportedFromResolution: Bool)

    public struct Choice: Equatable, Sendable {
        public let value: Int
        public let label: String
    }

    var isChoiceWithoutBitmap: Bool {
        if case .choice(_, supportedFromResolution: false) = self { true } else { false }
    }
}

/// A standard UVC 1.5 control. Field offset/size select one value inside a compound control (pan/tilt).
public struct ControlDefinition: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let unit: ControlUnit
    /// Bit index in the unit's bmControls.
    public let bit: Int
    public let selector: UInt8
    /// Total wire length of the control.
    public let length: Int
    public let fieldOffset: Int
    public let fieldSize: Int
    public let signed: Bool
    public let kind: ControlKind
    /// The toggle or mode control that, when automatic, makes this control read-only.
    public let automaticControlID: String?

    /// Whether the gating control's current value leaves this control under device control.
    /// Exposure modes are a bitmap: Manual (1) and Shutter priority (4) leave exposure time to the user.
    static func isAutomatic(gate: String, value: Int) -> Bool {
        gate == "exposure_mode" ? value & 0b0101 == 0 : value != 0
    }

    init(_ id: String, _ name: String, _ unit: ControlUnit, bit: Int, selector: UInt8, length: Int,
         fieldOffset: Int = 0, fieldSize: Int? = nil, signed: Bool = false, kind: ControlKind = .range,
         automatic: String? = nil) {
        self.id = id
        self.name = name
        self.unit = unit
        self.bit = bit
        self.selector = selector
        self.length = length
        self.fieldOffset = fieldOffset
        self.fieldSize = fieldSize ?? length
        self.signed = signed
        self.kind = kind
        automaticControlID = automatic
    }
}

public enum ControlCatalog {
    static let exposureModes: [ControlKind.Choice] = [
        .init(value: 1, label: "Manual"), .init(value: 2, label: "Auto"),
        .init(value: 4, label: "Shutter priority"), .init(value: 8, label: "Aperture priority"),
    ]
    static let powerLine: [ControlKind.Choice] = [
        .init(value: 0, label: "Off"), .init(value: 1, label: "50 Hz"),
        .init(value: 2, label: "60 Hz"), .init(value: 3, label: "Auto"),
    ]

    /// Ordered so that mode controls are applied before the values they gate.
    public static let all: [ControlDefinition] = [
        // Camera terminal (UVC 1.5 table 4-x, bmControls bit order).
        .init("exposure_mode", "Exposure mode", .cameraTerminal, bit: 1, selector: 0x02, length: 1,
              kind: .choice(exposureModes, supportedFromResolution: true)),
        .init("exposure_priority", "Low-light boost", .cameraTerminal, bit: 2, selector: 0x03, length: 1, kind: .toggle),
        .init("focus_auto", "Autofocus", .cameraTerminal, bit: 17, selector: 0x08, length: 1, kind: .toggle),
        .init("exposure_time", "Shutter speed", .cameraTerminal, bit: 3, selector: 0x04, length: 4, automatic: "exposure_mode"),
        .init("focus", "Focus", .cameraTerminal, bit: 5, selector: 0x06, length: 2, automatic: "focus_auto"),
        .init("iris", "Iris", .cameraTerminal, bit: 7, selector: 0x09, length: 2),
        .init("zoom", "Zoom", .cameraTerminal, bit: 9, selector: 0x0B, length: 2),
        .init("pan", "Pan", .cameraTerminal, bit: 11, selector: 0x0D, length: 8, fieldOffset: 0, fieldSize: 4, signed: true),
        .init("tilt", "Tilt", .cameraTerminal, bit: 11, selector: 0x0D, length: 8, fieldOffset: 4, fieldSize: 4, signed: true),
        .init("roll", "Roll", .cameraTerminal, bit: 13, selector: 0x0F, length: 2, signed: true),
        .init("privacy", "Privacy shutter", .cameraTerminal, bit: 18, selector: 0x11, length: 1, kind: .toggle),
        // Processing unit.
        .init("white_balance_auto", "Auto white balance", .processingUnit, bit: 12, selector: 0x0B, length: 1, kind: .toggle),
        .init("hue_auto", "Auto hue", .processingUnit, bit: 11, selector: 0x10, length: 1, kind: .toggle),
        .init("contrast_auto", "Auto contrast", .processingUnit, bit: 18, selector: 0x13, length: 1, kind: .toggle),
        .init("brightness", "Brightness", .processingUnit, bit: 0, selector: 0x02, length: 2, signed: true),
        .init("contrast", "Contrast", .processingUnit, bit: 1, selector: 0x03, length: 2, automatic: "contrast_auto"),
        .init("saturation", "Saturation", .processingUnit, bit: 3, selector: 0x07, length: 2),
        .init("sharpness", "Sharpness", .processingUnit, bit: 4, selector: 0x08, length: 2),
        .init("hue", "Hue", .processingUnit, bit: 2, selector: 0x06, length: 2, signed: true, automatic: "hue_auto"),
        .init("gamma", "Gamma", .processingUnit, bit: 5, selector: 0x09, length: 2),
        .init("white_balance", "White balance (K)", .processingUnit, bit: 6, selector: 0x0A, length: 2,
              automatic: "white_balance_auto"),
        .init("gain", "ISO (gain)", .processingUnit, bit: 9, selector: 0x04, length: 2, automatic: "exposure_mode"),
        .init("backlight_compensation", "HDR (backlight compensation)", .processingUnit, bit: 8, selector: 0x01, length: 2),
        .init("power_line_frequency", "Anti-flicker", .processingUnit, bit: 10, selector: 0x05, length: 1,
              kind: .choice(powerLine, supportedFromResolution: false)),
    ]

    public static func definition(_ id: String) -> ControlDefinition? { all.first { $0.id == id } }

    /// Human-readable value: shutter speed as a fraction of a second, pan/tilt in degrees and so on.
    public static func format(_ id: String, _ value: Int) -> String {
        switch id {
        case "exposure_time": ShutterSpeed.label(units: value)
        case "pan", "tilt": String(format: "%.0f°", Double(value) / 3600)
        case "roll": "\(value)°"
        case "white_balance": "\(value) K"
        case "zoom": String(format: "%.1f×", Double(value) / 100)
        default: "\(value)"
        }
    }
}

/// Shutter times as photographers write them. UVC exposure time is in 100 µs units.
public enum ShutterSpeed {
    public static func seconds(units: Int) -> Double { Double(units) / 10_000 }

    public static func label(units: Int) -> String { label(seconds: seconds(units: units)) }

    public static func label(seconds: Double) -> String {
        guard seconds > 0 else { return "0 s" }
        return seconds >= 0.5 ? String(format: "%.1f s", seconds) : "1/\(Int((1 / seconds).rounded())) s"
    }
}

/// Vendor extension units seen in Logitech webcams. Names follow public UVC driver projects;
/// LogiCam Tuner reports their presence but does not interpret or write them.
public enum KnownExtensionUnits {
    public static let names: [UUID: String] = [
        "69678EE4-410F-40DB-A850-7420D7D8240E": "Logitech device information",
        "49E40215-F434-47FE-B158-0E885023E51B": "Logitech video pipe",
        "FFE52D21-8030-4E2C-82D9-F587D00540BD": "Logitech peripheral control",
        "1F5D4CA9-DE11-4487-840D-50933C8EC8D1": "Logitech test/debug",
        "63610682-5070-49AB-B8CC-B3855E8D221D": "Logitech video extension (v1)",
        "63610682-5070-49AB-B8CC-B3855E8D2256": "Logitech user hardware control (v1)",
    ].reduce(into: [:]) { result, entry in
        if let uuid = UUID(uuidString: entry.key) { result[uuid] = entry.value }
    }
}
