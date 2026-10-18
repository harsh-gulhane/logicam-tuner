import CamDialKit
import Foundation

/// What the camera is doing right now while an app (or CamDial's preview) is streaming.
struct LiveStream: Equatable {
    /// Apps believed to be using the camera; empty when unknown.
    var apps: [CameraUser] = []
    var startedAt = Date()
    var width: Int32 = 0
    var height: Int32 = 0
    var configuredFrameRate: Double = 0
    /// Measured by CamDial's own connection to the stream; nil until it has frames.
    var measuredFrameRate: Double?
    var pixelFormat = ""
    /// Current camera control values, read once a second.
    var values: [String: Int] = [:]
    /// Every app seen using the camera during this stream, for the session summary.
    var everUsedBy: [String] = []
    /// Measured frame rates, for the session summary.
    var frameRateSamples: [Double] = []

    static let polledControls = ["exposure_mode", "exposure_time", "gain", "white_balance_auto", "white_balance",
                                 "focus_auto", "focus", "zoom", "backlight_compensation", "power_line_frequency",
                                 "exposure_priority", "brightness"]

    var resolution: String { width > 0 ? "\(width)×\(height)" : "—" }

    var appNames: String? { apps.isEmpty ? nil : apps.map(\.name).joined(separator: ", ") }
    var appsAreGuess: Bool { apps.contains { $0.evidence == .frontmost } }
}

/// One finished period of camera use by an app, kept so different apps can be compared.
struct CameraSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var app: String
    var appIsGuess: Bool
    var startedAt: Date
    var duration: TimeInterval
    var resolution: String
    var configuredFrameRate: Double
    var averageMeasuredFrameRate: Double?
    var pixelFormat: String
}

/// The last sessions, as JSON next to the presets.
struct SessionStore {
    static let limit = 30
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CamDial", isDirectory: true).appendingPathComponent("sessions.json")

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
    func update(feed: CameraFeed?, camera: Camera?, active: Bool, otherApp: Bool, io: DispatchQueue) {
        guard active, let feed, let camera else { finish(); return }
        var next = live ?? LiveStream()
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
        let fps = feed.isRunning ? feed.measuredFrameRate : 0
        if fps > 0 {
            if next.measuredFrameRate == nil {
                Diagnostics.note("stream: \(next.appNames ?? "unknown app"), \(next.resolution) \(next.pixelFormat), "
                                 + String(format: "%.0f fps configured, %.1f measured", next.configuredFrameRate, fps))
            }
            next.measuredFrameRate = fps
            next.frameRateSamples = Array((next.frameRateSamples + [fps]).suffix(3600))
        }
        if next != live { live = next }
        io.async { [weak self] in
            let values = camera.currentValues(LiveStream.polledControls)
            DispatchQueue.main.async {
                guard let self, var current = self.live, current.values != values else { return }
                current.values = values
                self.live = current
            }
        }
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
                                    appIsGuess: live.apps.isEmpty || live.appsAreGuess,
                                    startedAt: live.startedAt, duration: duration, resolution: live.resolution,
                                    configuredFrameRate: live.configuredFrameRate,
                                    averageMeasuredFrameRate: samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count),
                                    pixelFormat: live.pixelFormat)
        Diagnostics.note("session ended: \(session.app), \(session.resolution) at \(session.configuredFrameRate) fps, "
                         + "measured \(session.averageMeasuredFrameRate.map { String(format: "%.1f", $0) } ?? "none"), \(Int(duration)) s")
        sessions.insert(session, at: 0)
        sessions = Array(sessions.prefix(SessionStore.limit))
        try? store.save(sessions)
    }
}
