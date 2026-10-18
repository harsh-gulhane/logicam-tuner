import Foundation

/// A named set of control values for one camera model and unit.
public struct Preset: Codable, Equatable, Sendable {
    public var values: [String: Int]

    public init(values: [String: Int]) { self.values = values }

    /// Captures every writable control. Values locked by an automatic mode are skipped,
    /// because the camera owns them while that mode is on.
    public static func capture(_ camera: Camera) -> Preset {
        Preset(values: camera.readAll().reduce(into: [:]) { values, state in
            if state.isWritable { values[state.control.id] = state.current }
        })
    }

    public struct Failure: Sendable {
        public let control: String
        public let error: Error
    }

    /// Applies mode controls first so the values they gate become writable. Controls in `skipping`
    /// are left alone, e.g. those Smart Auto currently owns.
    public func apply(to camera: Camera, skipping: Set<String> = []) -> [Failure] {
        ControlCatalog.all.compactMap { definition in
            guard let value = values[definition.id], !skipping.contains(definition.id) else { return nil }
            do {
                let control = try camera.control(definition.id)
                if try camera.read(control).current != value { try camera.write(control, value: value) }
                return nil
            } catch {
                return Failure(control: definition.id, error: error)
            }
        }
    }
}

/// Stores presets as JSON under Application Support, keyed by the camera's persistent key.
public final class PresetStore: @unchecked Sendable {
    private struct File: Codable {
        var cameras: [String: CameraEntry] = [:]
    }

    private struct CameraEntry: Codable {
        var presets: [String: Preset] = [:]
        var startupPreset: String?
        var smartAuto: SmartAutoSettings?
    }

    public let url: URL
    private let lock = NSLock()

    public init(url: URL? = nil) {
        self.url = url ?? AppSupport.directory.appendingPathComponent("presets.json")
    }

    public func presets(for camera: CameraInfo) -> [String: Preset] {
        lock.withLock { load().cameras[camera.persistentKey]?.presets ?? [:] }
    }

    public func startupPreset(for camera: CameraInfo) -> String? {
        lock.withLock { load().cameras[camera.persistentKey]?.startupPreset }
    }

    public func smartAuto(for camera: CameraInfo) -> SmartAutoSettings {
        lock.withLock { load().cameras[camera.persistentKey]?.smartAuto ?? SmartAutoSettings() }
    }

    public func setSmartAuto(_ settings: SmartAutoSettings, for camera: CameraInfo) throws {
        try mutate(camera) { $0.smartAuto = settings }
    }

    public func save(_ preset: Preset, named name: String, for camera: CameraInfo) throws {
        try mutate(camera) { $0.presets[name] = preset }
    }

    public func delete(named name: String, for camera: CameraInfo) throws {
        try mutate(camera) { entry in
            entry.presets[name] = nil
            if entry.startupPreset == name { entry.startupPreset = nil }
        }
    }

    public func setStartupPreset(_ name: String?, for camera: CameraInfo) throws {
        try mutate(camera) { $0.startupPreset = name }
    }

    private func mutate(_ camera: CameraInfo, _ change: (inout CameraEntry) -> Void) throws {
        try lock.withLock {
            var file = load()
            change(&file.cameras[camera.persistentKey, default: CameraEntry()])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        }
    }

    private func load() -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        return (try? JSONDecoder().decode(File.self, from: data)) ?? File()
    }
}
