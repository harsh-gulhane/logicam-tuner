import CoreVideo
import Foundation
import QuartzCore
import Vision

/// User choices for Smart Auto, stored per camera.
public struct SmartAutoSettings: Codable, Equatable, Sendable {
    public var exposure = false
    public var whiteBalance = false
    /// Exposure compensation in EV (-2...2).
    public var exposureBias = 0.0
    public var facePriority = true
    /// Highest gain Smart Auto may use, as a share of the camera's range.
    public var maxGain = 1.0
    /// In low light, once gain reaches half of `maxGain`, shutter time may grow until video drops to
    /// this frame rate. Lower is brighter and less noisy, but less smooth. 0 (or any value at or above
    /// the stream's rate) keeps the stream's frame rate.
    public var minimumFrameRate = 15.0
    /// -1 (cooler) ... 1 (warmer).
    public var warmth = 0.0

    public init() {}

    public var isEnabled: Bool { exposure || whiteBalance }

    /// Controls Smart Auto writes while enabled; presets and resets leave these alone.
    public var ownedControls: Set<String> {
        Set(exposure ? ["exposure_mode", "exposure_time", "gain", "exposure_priority"] : [])
            .union(whiteBalance ? ["white_balance_auto", "white_balance"] : [])
    }

    public init(from decoder: Decoder) throws {
        // Decode leniently so settings written by older versions keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Bool.self, forKey: .exposure) ?? false
        whiteBalance = try c.decodeIfPresent(Bool.self, forKey: .whiteBalance) ?? false
        exposureBias = try c.decodeIfPresent(Double.self, forKey: .exposureBias) ?? 0
        facePriority = try c.decodeIfPresent(Bool.self, forKey: .facePriority) ?? true
        maxGain = try c.decodeIfPresent(Double.self, forKey: .maxGain) ?? 1
        minimumFrameRate = try c.decodeIfPresent(Double.self, forKey: .minimumFrameRate) ?? 15
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
    }
}

public struct SmartAutoStatus: Equatable, Sendable {
    public var exposure: ExposureSetting?
    public var whiteBalance: Int?
    /// Exposure is metering a face, including one face detection missed a moment ago.
    public var faceDetected = false
    public var adjusting = false
    /// Exposure is at its brightest allowed setting and the picture is still too dark.
    public var needsMoreLight = false
    /// Why a feature is not running, e.g. the camera lacks manual exposure.
    public var problem: String?
}

/// Runs the software exposure and white-balance controllers on frames from a `CameraFeed`
/// and writes the results to the camera through the caller's serial I/O queue.
public final class SmartAuto: @unchecked Sendable {
    public let camera: Camera
    public let feed: CameraFeed
    /// Called on the main queue, at most twice a second.
    public var onStatus: ((SmartAutoStatus) -> Void)?
    /// Called on an internal queue with every analyzed frame (about five a second), for diagnostics.
    public var onStatistics: ((FrameStatistics) -> Void)?

    private let io: DispatchQueue
    private let lock = NSLock()
    private var _settings = SmartAutoSettings()

    /// Serializes the controller state below between frame callbacks and camera refreshes.
    private let state = DispatchQueue(label: "logicam.smartauto")
    private var exposureController = ExposureController()
    private var faceMetering = FaceMetering()
    private var whiteBalanceController = WhiteBalanceController()
    private var limits: CameraLimits?
    private var exposure: ExposureSetting?
    private var kelvin: Int?
    private var nextAnalysis = 0.0, nextFaceDetection = 0.0, nextStatus = 0.0
    /// Writes queued on `io` that the camera has not received yet, and when the last one arrived.
    private var writesInFlight = 0
    private var lastWriteLanded = 0.0
    private var faces: [CGRect] = []
    private var status = SmartAutoStatus()

    /// Camera facts read once per activation; refreshed with `refreshCameraState()`.
    struct CameraLimits {
        var time: ControlState?
        var gain: ControlState?
        var whiteBalance: ControlState?
        var flickerPeriod: Double?
        /// Whether the camera may lengthen frames for longer exposures (UVC auto-exposure priority).
        var framesMayLengthen: Bool
    }

    public init(camera: Camera, feed: CameraFeed, io: DispatchQueue) {
        self.camera = camera
        self.feed = feed
        self.io = io
        feed.onFrame = { [weak self] buffer in self?.process(buffer) }
    }

    public var settings: SmartAutoSettings {
        get { lock.withLock { _settings } }
        set {
            let old = lock.withLock { () -> SmartAutoSettings in
                defer { _settings = newValue }
                return _settings
            }
            if newValue.exposure && !old.exposure || newValue.whiteBalance && !old.whiteBalance { refreshCameraState() }
        }
    }

    /// Re-reads ranges, anti-flicker and low-light settings, and takes manual control of the features
    /// that are enabled. Call after changing camera settings outside Smart Auto.
    public func refreshCameraState() {
        io.async { [weak self] in
            guard let self else { return }
            let settings = self.settings
            func read(_ id: String) -> ControlState? { try? self.camera.read(id) }
            func writeIfNeeded(_ id: String, _ value: Int) {
                if let s = read(id), s.current != value, s.info.contains(.set) { try? self.camera.write(id, value: value) }
            }
            if settings.exposure {
                writeIfNeeded("exposure_mode", 1)
                // Exposures longer than a frame need the camera to lower its frame rate.
                writeIfNeeded("exposure_priority", 1)
            }
            if settings.whiteBalance { writeIfNeeded("white_balance_auto", 0) }
            let flicker: Double? = switch read("power_line_frequency")?.current {
            case 1: 100 // 50 Hz mains flickers at 100 Hz: 10 ms
            case 2, 3: 10_000.0 / 120 // 60 Hz, and "auto" assumes the stricter 60 Hz period
            default: nil
            }
            let limits = CameraLimits(time: read("exposure_time"), gain: read("gain"),
                                      whiteBalance: read("white_balance"), flickerPeriod: flicker,
                                      framesMayLengthen: read("exposure_priority")?.current == 1)
            var problem: String?
            if settings.exposure, limits.time?.isWritable != true { problem = "This camera does not allow manual exposure." }
            if settings.whiteBalance, limits.whiteBalance?.isWritable != true {
                problem = "This camera does not allow manual white balance."
            }
            self.state.async {
                self.limits = limits
                self.exposure = limits.time.map { ExposureSetting(time: $0.current, gain: limits.gain?.current ?? 0) }
                self.kelvin = limits.whiteBalance?.current
                self.status.problem = problem
            }
        }
    }

    /// Analysis runs off the capture queue so slow frames never make the camera drop frames.
    /// While one frame is being analysed, newer frames are skipped rather than queued.
    private func process(_ buffer: CVPixelBuffer) {
        let start = lock.withLock { () -> Bool in
            guard !analyzing else { return false }
            analyzing = true
            return true
        }
        guard start else { return }
        state.async {
            self.analyze(buffer)
            self.lock.withLock { self.analyzing = false }
        }
    }

    private var analyzing = false

    private func analyze(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now >= nextAnalysis, let limits else { return }
        nextAnalysis = now + 0.2
        let settings = self.settings
        guard settings.isEnabled || onStatistics != nil else { return }
        exposureController.bias = settings.exposureBias
        exposureController.facePriority = settings.facePriority
        whiteBalanceController.warmthBias = settings.warmth * 0.08

        if now >= nextFaceDetection {
            nextFaceDetection = now + 0.5
            faces = Self.detectFaces(buffer)
        }

        guard var stats = FrameAnalyzer.analyze(buffer, faces: settings.facePriority ? faces : [],
                                                searchCenter: whiteBalanceController.searchCenter) else { return }
        onStatistics?(stats)
        // A face detection missed for a moment keeps the face in the metering.
        stats = faceMetering.update(stats, at: now)
        exposureController.faceWeight = faceMetering.weight
        let settle = Self.settleTime(frameDuration: feed.frameDuration, measuredFrameRate: feed.measuredFrameRate,
                                     exposureTime: settings.exposure ? exposure.map { Double($0.time) / 10_000 } : nil)
        var adjusting = false, needsMoreLight = false

        if settings.exposure, status.problem == nil, let time = limits.time, let current = exposure,
           writesInFlight == 0, now - lastWriteLanded >= settle, let lo = time.minimum, let hi = time.maximum {
            let gain = limits.gain
            let gainRange = (gain?.minimum ?? 0)...(gain?.maximum ?? 0)
            let frameUnits = Int(feed.frameDuration * 10_000)
            let exposureLimits = ExposureLimits(
                time: lo...hi, gain: gainRange, frameTime: frameUnits,
                maxTime: limits.framesMayLengthen && settings.minimumFrameRate > 0
                    ? max(frameUnits, Int(10_000 / settings.minimumFrameRate)) : frameUnits,
                maxGain: gainRange.lowerBound + Int(Double(gainRange.upperBound - gainRange.lowerBound) * settings.maxGain),
                flickerPeriod: limits.flickerPeriod)
            if let next = exposureController.update(stats, current: current, limits: exposureLimits) {
                write([(time.control, next.time, current.time)] + (gain.map { [($0.control, next.gain, current.gain)] } ?? []))
                exposure = next
            }
            adjusting = adjusting || exposureController.isCorrecting
            needsMoreLight = exposureController.lastError > ExposureController.stopThreshold
                && exposure == ExposureController.brightest(exposureLimits)
        }

        // White balance also waits for an exposure change made just above, so it never measures a frame
        // halfway through one.
        if settings.whiteBalance, status.problem == nil, let wb = limits.whiteBalance, let current = kelvin,
           writesInFlight == 0, now - lastWriteLanded >= max(settle, 0.4), let lo = wb.minimum, let hi = wb.maximum {
            if let next = whiteBalanceController.update(stats, currentKelvin: current, range: lo...hi) {
                write([(wb.control, next, current)])
                kelvin = next
            }
            adjusting = adjusting || whiteBalanceController.isCorrecting
        }

        status.exposure = settings.exposure ? exposure : nil
        status.whiteBalance = settings.whiteBalance ? kelvin : nil
        status.faceDetected = settings.facePriority && faceMetering.weight > 0
        status.adjusting = adjusting && !needsMoreLight
        status.needsMoreLight = needsMoreLight
        if now >= nextStatus {
            nextStatus = now + 0.5
            let snapshot = status
            DispatchQueue.main.async { [weak self] in self?.onStatus?(snapshot) }
        }
    }

    /// Sends the changed values in one I/O turn, so other camera requests on `io` cannot land between
    /// shutter and gain, and notes when the camera has them: settling is timed from then, not from
    /// when the change was decided, since `io` may be busy with other requests.
    private func write(_ changes: [(control: CameraControl, value: Int, previous: Int)]) {
        let changed = changes.filter { $0.value != $0.previous }
        guard !changed.isEmpty else { return }
        writesInFlight += 1
        io.async { [self] in
            for change in changed { try? camera.setCurrent(change.control, value: change.value) }
            let landed = CACurrentMediaTime()
            state.async { [self] in
                writesInFlight -= 1
                lastWriteLanded = landed
            }
        }
    }

    /// How long a change takes to show in the analysed frames once the camera has it: four frames, at
    /// least 0.3 s. Long exposures make frames longer than the configured rate, so frames are timed by
    /// the slowest of the configured duration, the measured interval and the exposure time.
    static func settleTime(frameDuration: Double, measuredFrameRate: Double, exposureTime: Double?) -> Double {
        let frame = max(frameDuration, measuredFrameRate > 0 ? 1 / measuredFrameRate : 0, exposureTime ?? 0)
        return max(0.3, 4 * frame)
    }

    static func detectFaces(_ buffer: CVPixelBuffer) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        // Vision uses a bottom-left origin; the analyzer uses top-left.
        return (request.results ?? []).map(\.boundingBox)
            .filter { $0.width > 0.04 }
            .map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) }
    }
}
