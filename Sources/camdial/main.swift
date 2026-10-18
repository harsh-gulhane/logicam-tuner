import AVFoundation
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
  who                          show whether the camera is streaming and which app is likely using it
  auto [features] [options]    run Smart Auto until interrupted (turns the camera on)
      features: exposure, white-balance (both when none given)
      --bias <ev>                exposure compensation, e.g. -0.5
      --warmth <-1...1>          white balance warmth
      --no-face                  meter the whole scene instead of faces
      --min-fps <n>              lowest frame rate low light may drop to (default 15; 0 keeps it)
      --max-gain <0...1>         share of the gain range to use (default 1)
      --seconds <n>              stop after n seconds
      --watch                    only print measurements; change nothing
      --fps <n>                  frame rate to request when no other app is streaming (default 30)

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
    let formatted = ControlCatalog.format(d.id, state.current)
    if formatted != "\(state.current)" { value += " (\(formatted))" }
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
    case "who":
        let camera = try selectCamera()
        let streaming = CameraFeed(camera.info)?.isStreamingSomewhere ?? false
        print("\(camera.info.name): \(streaming ? "streaming" : "idle")")
        let capturing = CameraUsers.audioCapturingApps()
        print("apps capturing audio: " + (capturing.isEmpty ? "none" : capturing.map { $0.name }.joined(separator: ", ")))
        if streaming {
            let users = CameraUsers.likelyUsers()
            print("likely camera users: " + (users.isEmpty ? "unknown" : users.map {
                "\($0.name) (\($0.evidence == .microphone ? "also using the microphone" : "frontmost camera app"))"
            }.joined(separator: ", ")))
        }
    case "auto":
        try runSmartAuto()
    case "help", "-h", "--help":
        print(usage)
    default:
        throw CLIError(description: "unknown command \(command)\n\n\(usage)")
    }
}

func runSmartAuto() throws {
    let bias = takeOption("--bias").flatMap(Double.init) ?? 0
    let warmth = takeOption("--warmth").flatMap(Double.init) ?? 0
    let seconds = takeOption("--seconds").flatMap(Double.init)
    let noFace = takeFlag("--no-face")
    let minFPS = takeOption("--min-fps").flatMap(Double.init)
    let maxGain = takeOption("--max-gain").flatMap(Double.init)
    let watch = takeFlag("--watch")
    let fps = takeOption("--fps").flatMap(Double.init)
    let features = Set(args)
    guard features.isSubset(of: ["exposure", "white-balance"]) else {
        throw CLIError(description: "unknown auto feature in \(args.joined(separator: " "))")
    }
    let camera = try selectCamera()

    let access = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { granted = $0; access.signal() }
    access.wait()
    guard granted else { throw CLIError(description: "camera access denied; allow it in System Settings → Privacy & Security → Camera") }
    guard let feed = CameraFeed(camera.info) else { throw CLIError(description: "AVFoundation cannot open \(camera.info.name)") }

    if let fps { feed.preferredFrameRate = fps }
    let smart = SmartAuto(camera: camera, feed: feed, io: DispatchQueue(label: "camdial.io"))
    var settings = SmartAutoSettings()
    settings.exposure = !watch && (features.isEmpty || features.contains("exposure"))
    settings.whiteBalance = !watch && (features.isEmpty || features.contains("white-balance"))
    settings.exposureBias = bias
    settings.warmth = warmth
    settings.facePriority = !noFace
    if let minFPS { settings.minimumFrameRate = minFPS }
    if let maxGain { settings.maxGain = min(max(maxGain, 0), 1) }
    smart.settings = settings
    smart.refreshCameraState()
    smart.onStatistics = { stats in
        let face = stats.faceLuminance.map { String(format: "face %.3f", $0) } ?? "no face"
        let cast = stats.neutralCast.map { String(format: "neutral warmth %+.3f tint %+.3f", $0.warmth, $0.tint) } ?? "no neutrals"
        print(String(format: "%.0f fps  scene %.3f  %@  clipped %.1f%%  %@ (%.0f%%)  average warmth %+.3f", feed.measuredFrameRate, stats.sceneLuminance, face,
                     stats.clippedFraction * 100, cast, stats.neutralFraction * 100, stats.averageCast.warmth))
    }
    smart.onStatus = { status in
        var parts: [String] = []
        if let e = status.exposure { parts.append("shutter \(ShutterSpeed.label(units: e.time)) gain \(e.gain)") }
        if let k = status.whiteBalance { parts.append("\(k) K") }
        if status.adjusting { parts.append("adjusting") }
        if status.needsMoreLight { parts.append("too dark: allow a lower frame rate or add light") }
        if let problem = status.problem { parts.append(problem) }
        if !parts.isEmpty { print("  -> " + parts.joined(separator: ", ")) }
    }
    feed.start()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { exit(0) }
    interrupt.resume()
    if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) } }
    dispatchMain()
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("camdial: \(error)\n".utf8))
    exit(1)
}
