import CamDialKit
import Foundation

let usage = """
usage: camdial <command> [options]

commands:
  list                         list attached UVC cameras
  describe [--raw]             show units, extension units and supported controls
  get [control...]             read controls (all when none given)
  set <control>=<value>...     write controls
  reset [control...]           restore camera defaults (all when none given)
  preset save <name>           save current values as a preset
  preset apply <name>          apply a saved preset
  preset list                  list saved presets
  preset delete <name>         delete a preset

options:
  --camera <index|serial>      choose a camera (default: first Logitech camera, else first camera)
  --json                       machine-readable output for list/get
"""

struct CLIError: Error, CustomStringConvertible { let description: String }

var args = Array(CommandLine.arguments.dropFirst())
func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let cameraSelector = takeOption("--camera")
let json = takeFlag("--json")

func selectCamera() throws -> Camera {
    let cameras = Camera.list()
    guard !cameras.isEmpty else { throw CLIError(description: "no UVC cameras found") }
    let info: CameraInfo
    if let selector = cameraSelector {
        if let index = Int(selector), cameras.indices.contains(index) {
            info = cameras[index]
        } else if let match = cameras.first(where: { $0.serial == selector }) {
            info = match
        } else {
            throw CLIError(description: "no camera matches \(selector); run `camdial list`")
        }
    } else {
        info = cameras.first(where: \.isLogitech) ?? cameras[0]
    }
    return try Camera(info)
}

func render(_ state: ControlState) -> String {
    let d = state.control.definition
    var value = "\(state.current)"
    if let label = state.choices.first(where: { $0.value == state.current })?.label { value += " (\(label))" }
    if case .toggle = d.kind { value = state.current != 0 ? "on" : "off" }
    var detail: [String] = []
    if let lo = state.minimum, let hi = state.maximum { detail.append("range \(lo)...\(hi)") }
    if let step = state.resolution, d.kind == .range, step > 1 { detail.append("step \(step)") }
    if let def = state.defaultValue { detail.append("default \(def)") }
    if !state.choices.isEmpty, d.kind != .toggle { detail.append("choices " + state.choices.map { "\($0.value)=\($0.label)" }.joined(separator: ", ")) }
    if state.lockedByAutomaticMode { detail.append("locked by auto mode") }
    else if !state.info.contains(.set) { detail.append("read-only") }
    return "\(d.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(value.padding(toLength: 14, withPad: " ", startingAt: 0)) \(detail.joined(separator: "; "))"
}

func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func parseAssignments(_ items: [String]) throws -> [(String, Int)] {
    try items.map { item in
        let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CLIError(description: "expected control=value, got \(item)") }
        let raw = parts[1].lowercased()
        let value: Int? = switch raw {
        case "on", "true", "auto": raw == "auto" ? nil : 1
        case "off", "false": 0
        default: Int(raw)
        }
        if raw == "auto", let definition = ControlCatalog.definition(parts[0]),
           case let .choice(choices, _) = definition.kind,
           let auto = choices.first(where: { $0.label.lowercased() == "auto" }) {
            return (parts[0], auto.value)
        }
        guard let value else { throw CLIError(description: "invalid value in \(item)") }
        return (parts[0], value)
    }
}

func run() throws {
    guard let command = args.first else { print(usage); return }
    args.removeFirst()
    switch command {
    case "list":
        let cameras = Camera.list()
        if json {
            try printJSON(cameras.map { ["name": $0.name, "vendor_id": String(format: "0x%04x", $0.vendorID),
                                         "product_id": String(format: "0x%04x", $0.productID), "serial": $0.serial,
                                         "firmware": String(format: "0x%04x", $0.firmware), "key": $0.persistentKey] })
        } else if cameras.isEmpty {
            print("no UVC cameras found")
        } else {
            for (i, c) in cameras.enumerated() {
                print(String(format: "[%d] %@  %04x:%04x  serial %@  fw %04x", i, c.name, c.vendorID, c.productID, c.serial, c.firmware))
            }
        }
    case "describe":
        let camera = try selectCamera()
        if takeFlag("--raw") {
            print(camera.configurationDescriptor.map { String(format: "%02x", $0) }.joined())
            return
        }
        let t = camera.topology
        print("\(camera.info.name)  UVC \(String(t.uvcVersion >> 8)).\(String(format: "%02x", t.uvcVersion & 0xff))  VC interface \(t.interfaceNumber)")
        if let ct = t.cameraTerminal { print(String(format: "camera terminal   id %d  controls 0x%llx", ct.id, ct.controlBits)) }
        for pu in t.processingUnits { print(String(format: "processing unit   id %d  controls 0x%llx", pu.id, pu.controlBits)) }
        for xu in t.extensionUnits {
            let name = KnownExtensionUnits.names[xu.guid] ?? "unknown vendor unit"
            print(String(format: "extension unit    id %d  %@  %d controls  (%@)", xu.id, xu.guid.uuidString, xu.controlCount, name))
        }
        print("supported standard controls: " + camera.controls.map(\.id).joined(separator: ", "))
    case "get":
        let camera = try selectCamera()
        let states = args.isEmpty ? camera.readAll() : try args.map { try camera.read($0) }
        if json {
            try printJSON(states.map { s -> [String: Any] in
                var o: [String: Any] = ["id": s.control.id, "value": s.current, "writable": s.isWritable,
                                        "info": String(format: "0x%02x", s.info.rawValue)]
                if let v = s.minimum { o["min"] = v }
                if let v = s.maximum { o["max"] = v }
                if let v = s.defaultValue { o["default"] = v }
                return o
            })
        } else {
            states.forEach { print(render($0)) }
        }
    case "set":
        let camera = try selectCamera()
        guard !args.isEmpty else { throw CLIError(description: "set needs control=value") }
        for (id, value) in try parseAssignments(args) {
            try camera.write(id, value: value)
            print(render(try camera.read(id)))
        }
    case "reset":
        let camera = try selectCamera()
        let targets = args.isEmpty ? camera.controls : try args.map { try camera.control($0) }
        for control in targets {
            guard let state = try? camera.read(control), let def = state.defaultValue, state.info.contains(.set) else { continue }
            do { try camera.write(control, value: def) } catch { print("skip \(control.id): \(error)") }
        }
        camera.readAll().forEach { print(render($0)) }
    case "preset":
        let store = PresetStore()
        guard let sub = args.first else { throw CLIError(description: "preset needs save|apply|list|delete") }
        let name = args.dropFirst().first
        switch sub {
        case "list":
            let camera = try selectCamera()
            store.presets(for: camera.info).keys.sorted().forEach { print($0) }
        case "save":
            guard let name else { throw CLIError(description: "preset save needs a name") }
            let camera = try selectCamera()
            let preset = Preset.capture(camera)
            try store.save(preset, named: name, for: camera.info)
            print("saved \(name): \(preset.values.count) controls")
        case "apply":
            guard let name else { throw CLIError(description: "preset apply needs a name") }
            let camera = try selectCamera()
            guard let preset = store.presets(for: camera.info)[name] else { throw CLIError(description: "no preset \(name)") }
            for failure in preset.apply(to: camera) { print("skip \(failure.control): \(failure.error)") }
            camera.readAll().forEach { print(render($0)) }
        case "delete":
            guard let name else { throw CLIError(description: "preset delete needs a name") }
            let camera = try selectCamera()
            try store.delete(named: name, for: camera.info)
        default:
            throw CLIError(description: "unknown preset command \(sub)")
        }
    case "help", "-h", "--help":
        print(usage)
    default:
        throw CLIError(description: "unknown command \(command)\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("camdial: \(error)\n".utf8))
    exit(1)
}
