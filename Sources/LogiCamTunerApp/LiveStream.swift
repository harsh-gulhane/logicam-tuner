import LogiCamKit
import Foundation

/// What the camera is doing right now while an app (or LogiCam Tuner's preview) is streaming.
struct LiveStream: Equatable {
    var camera: VideoCamera
    /// Apps believed to be using the camera; empty when unknown.
    var apps: [CameraUser] = []
    var startedAt = Date()
    var width: Int32 = 0
    var height: Int32 = 0
    var configuredFrameRate: Double = 0
    /// Measured by LogiCam Tuner's own connection to the stream; nil until it has frames.
    var measuredFrameRate: Double?
    var pixelFormat = ""
    /// Current camera control values, read once a second; UVC cameras only.
    var values: [String: Int] = [:]
    /// Exposure and colour reported with the frames, by cameras without controls.
    var metadata: FrameMetadata?
    /// Every app seen using the camera during this stream, for the session summary.
    var everUsedBy: [String] = []
    /// Measured frame rates, for the session summary.
    var frameRateSamples: [Double] = []

    static let polledControls = ["exposure_mode", "exposure_time", "gain", "white_balance_auto", "white_balance",
                                 "focus_auto", "focus", "zoom", "backlight_compensation", "power_line_frequency",
                                 "exposure_priority", "brightness"]

    var resolution: String { width > 0 ? "\(width)×\(height)" : "—" }
    /// Set when LogiCam Tuner replaced a slow mode the app chose, e.g. "2304×1296 · 5 fps".
    var upgradedFrom: String?

    var appNames: String? { apps.isEmpty ? nil : apps.map(\.name).joined(separator: ", ") }
    var appsAreGuess: Bool { apps.contains { $0.evidence == .frontmost } }
}

/// One finished period of camera use by an app, kept so different apps can be compared.
struct CameraSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var app: String
    /// Missing in sessions recorded before other cameras were supported.
    var camera: String?
    var appIsGuess: Bool
    var startedAt: Date
    var duration: TimeInterval
    var resolution: String
    var configuredFrameRate: Double
    var averageMeasuredFrameRate: Double?
    var pixelFormat: String
    /// The slow mode the app chose before LogiCam Tuner switched it, if it did.
    var upgradedFrom: String?
}

/// The last sessions, as JSON next to the presets.
struct SessionStore {
    static let limit = 30
    let url = AppSupport.directory.appendingPathComponent("sessions.json")

    func load() -> [CameraSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([CameraSession].self, from: data)) ?? []
    }

    func save(_ sessions: [CameraSession]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Array(sessions.prefix(Self.limit))).write(to: url, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// When the floating overlay is shown.
enum OverlayMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case whileInUse = "While an app uses the camera"
    case always = "Always"
    var id: String { rawValue }
}

/// Tracks the live stream and records sessions. Kept apart from `AppModel` so its once-a-second
/// updates redraw only the overlay and the session list, not every control.
@MainActor
final class LiveMonitor: ObservableObject {
    @Published private(set) var live: LiveStream?
    @Published private(set) var sessions: [CameraSession]
    private let store = SessionStore()
    private var ticks = 0
    /// Whether the current stream belongs to another app (so it is worth recording).
    private var recording = false

    init() { sessions = store.load() }

    /// Called once a second. `active` is true while the camera streams for another app or the preview.
    /// `camera` is the UVC control connection, for cameras that have one.
    func update(feed: CameraFeed?, camera: Camera?, active: Bool, otherApp: Bool, io: DispatchQueue) {
        guard active, let feed else { finish(); return }
        // Each camera's stream is its own session.
        if let live, live.camera.id != feed.camera.id { finish() }
        var next = live ?? LiveStream(camera: feed.camera)
        if live == nil { ticks = 0 }
        ticks += 1
        recording = recording || otherApp
        // Call apps may open the microphone a moment after the camera, so look every second until
        // something is found, then every few seconds as apps join or leave. A brief gap (e.g. a
        // muted call that pauses its microphone) keeps the previous list.
        if otherApp, next.apps.isEmpty || ticks % 3 == 0 {
            let users = CameraUsers.likelyUsers()
            if !users.isEmpty { next.apps = users }
            for user in users where !next.everUsedBy.contains(user.name) { next.everUsedBy.append(user.name) }
        }
        let d = feed.dimensions
        next.width = d.width
        next.height = d.height
        next.configuredFrameRate = feed.configuredFrameRate
        next.pixelFormat = feed.pixelFormat
        next.metadata = feed.metadata
        let fps = feed.isRunning ? feed.measuredFrameRate : 0
        if fps > 0 {
            if next.measuredFrameRate == nil {
                let reported = next.metadata.map { m in
                    [m.exposureTime.map(ShutterSpeed.label(seconds:)), m.iso.map { String(format: "ISO %.0f", $0) },
                     m.colorTemperature.map { "\($0) K" }, m.lux.map { "\($0) lux" }].compactMap { $0 }.joined(separator: " ")
                }
                Diagnostics.note("stream: \(next.appNames ?? "unknown app") on \(next.camera.name), \(next.resolution) \(next.pixelFormat), "
                                 + String(format: "%.0f fps configured, %.1f measured", next.configuredFrameRate, fps)
                                 + (reported.map { ", camera reports \($0)" } ?? ""))
            }
            next.measuredFrameRate = fps
            next.frameRateSamples = Array((next.frameRateSamples + [fps]).suffix(3600))
        }
        if next != live { live = next }
        guard let camera else { return }
        io.async { [weak self] in
            let values = camera.currentValues(LiveStream.polledControls)
            DispatchQueue.main.async {
                guard let self, var current = self.live, current.camera.uvc == camera.info, current.values != values else { return }
                current.values = values
                self.live = current
            }
        }
    }

    func noteUpgrade(from mode: String) {
        live?.upgradedFrom = mode
    }

    func clearSessions() {
        sessions = []
        try? store.save([])
    }

    private func finish() {
        defer { live = nil; recording = false }
        guard let live, recording else { return }
        let duration = Date().timeIntervalSince(live.startedAt)
        guard duration >= 3 else { return }
        let samples = live.frameRateSamples
        let session = CameraSession(app: live.everUsedBy.isEmpty ? "Unknown app" : live.everUsedBy.joined(separator: ", "),
                                    camera: live.camera.name,
                                    appIsGuess: live.apps.isEmpty || live.appsAreGuess,
                                    startedAt: live.startedAt, duration: duration, resolution: live.resolution,
                                    configuredFrameRate: live.configuredFrameRate,
                                    averageMeasuredFrameRate: samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count),
                                    pixelFormat: live.pixelFormat, upgradedFrom: live.upgradedFrom)
        Diagnostics.note("session ended: \(session.app) on \(live.camera.name), \(session.resolution) at \(session.configuredFrameRate) fps, "
                         + "measured \(session.averageMeasuredFrameRate.map { String(format: "%.1f", $0) } ?? "none"), \(Int(duration)) s")
        sessions.insert(session, at: 0)
        sessions = Array(sessions.prefix(SessionStore.limit))
        try? store.save(sessions)
    }
}
