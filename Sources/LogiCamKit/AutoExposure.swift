import Foundation

/// Exposure time (UVC 100 µs units) and gain written together.
public struct ExposureSetting: Equatable, Sendable {
    public var time: Int
    public var gain: Int

    public init(time: Int, gain: Int) {
        self.time = time
        self.gain = gain
    }
}

public struct ExposureLimits: Equatable, Sendable {
    /// Ranges the camera reports.
    public var time: ClosedRange<Int>
    public var gain: ClosedRange<Int>
    /// Longest exposure that keeps the current frame rate (longer when low-light boost is on).
    public var maxTime: Int
    /// Highest gain the user accepts; more gain means more noise.
    public var maxGain: Int
    /// Mains flicker period in exposure units (100 at 50 Hz, 83.3 at 60 Hz), nil when anti-flicker is off.
    public var flickerPeriod: Double?

    public init(time: ClosedRange<Int>, gain: ClosedRange<Int>, maxTime: Int, maxGain: Int, flickerPeriod: Double?) {
        self.time = time
        self.gain = gain
        self.maxTime = min(max(maxTime, time.lowerBound), time.upperBound)
        self.maxGain = min(max(maxGain, gain.lowerBound), gain.upperBound)
        self.flickerPeriod = flickerPeriod
    }

    /// The camera does not report what its gain units mean; the controller assumes the full range is
    /// about +3 EV (8x). Feedback corrects any error, it only affects how quickly exposure converges.
    var gainUnit: Double { max(Double(gain.upperBound - gain.lowerBound), 1) / 8 }
}

/// Feedback auto-exposure that meters faces first and changes exposure only when the error is
/// clearly visible, so the picture does not "breathe" while someone talks or moves.
///
/// Differences from typical webcam firmware AE:
/// - Face priority: a backlit face is exposed for the face, not the window behind it.
/// - Hysteresis: corrections start at a 0.25 EV error and stop at 0.08 EV.
/// - Prefers shutter time over gain, so the image stays as clean as the frame rate allows.
/// - Snaps shutter time to whole mains periods so artificial light does not band.
public struct ExposureController: Sendable {
    /// Exposure compensation in EV.
    public var bias: Double = 0
    public var facePriority = true
    /// Linear luminance targets: about 44% and 51% sRGB grey respectively. The face target is kept
    /// moderate and blended with the scene, because skin reflectance varies widely between people.
    static let sceneTarget = 0.16
    static let faceTarget = 0.22
    static let startThreshold = 0.25
    static let stopThreshold = 0.08
    /// With anti-flicker, shutter time moves in whole mains periods. Smaller corrections are made
    /// with gain at the current shutter time: the gain model is approximate, and re-splitting
    /// exposure between a coarse shutter step and gain on every correction can cycle between two settings.
    static let shutterStepThreshold = 0.5

    public private(set) var isCorrecting = false
    /// The most recent smoothed error in EV.
    public private(set) var lastError = 0.0
    private var smoothedError: Double?

    public init() {}

    /// How many EV the picture should move by, positive when it is too dark.
    public func error(for stats: FrameStatistics) -> Double {
        func ev(_ target: Double, _ measured: Double) -> Double { log2(target / max(measured, 1e-4)) }
        let scene = ev(Self.sceneTarget, stats.sceneLuminance)
        var error: Double
        if facePriority, let face = stats.faceLuminance {
            // Mostly the face, with some scene so the background is not thrown away entirely.
            error = 0.65 * ev(Self.faceTarget, face) + 0.35 * scene
        } else {
            error = scene
            // Without a face, hold back when a lot of the centre is blown out.
            if stats.clippedFraction > 0.03 { error = min(error, 0) - min(1, (stats.clippedFraction - 0.03) * 8) }
        }
        return error + bias
    }

    /// Returns a new setting when exposure should change.
    public mutating func update(_ stats: FrameStatistics, current: ExposureSetting, limits: ExposureLimits) -> ExposureSetting? {
        let raw = error(for: stats)
        let error = smoothedError.map { 0.5 * $0 + 0.5 * raw } ?? raw
        smoothedError = error
        lastError = error
        // A setting from before Smart Auto may break the limits (e.g. a 1/5 s manual shutter that
        // costs frame rate); move it inside them even when brightness already looks right.
        let outsideLimits = current.time > limits.maxTime || current.gain > limits.maxGain
        if !outsideLimits, abs(error) < (isCorrecting ? Self.stopThreshold : Self.startThreshold) {
            isCorrecting = false
            return nil
        }
        isCorrecting = true
        // Half the error per step: the feedback loop converges even when the gain model is 2x off.
        let step = min(max(error * 0.5, -1.5), 1.0)
        let ev = Self.ev(current, limits) + step
        var next = Self.setting(forEV: ev, limits)
        if let period = limits.flickerPeriod, next.time != current.time, abs(error) < Self.shutterStepThreshold,
           Self.isFlickerSafe(current.time, period: period, limits),
           let gainOnly = Self.setting(forEV: ev, time: current.time, limits) {
            next = gainOnly
        }
        guard next != current else { return nil }
        smoothedError = nil // the next frames show the new exposure
        return next
    }

    /// log2 of total exposure: shutter time times gain.
    static func ev(_ setting: ExposureSetting, _ limits: ExposureLimits) -> Double {
        log2(Double(max(setting.time, 1))) + log2(1 + Double(max(setting.gain - limits.gain.lowerBound, 0)) / limits.gainUnit)
    }

    /// The brightest setting the limits allow.
    public static func brightest(_ limits: ExposureLimits) -> ExposureSetting { setting(forEV: 64, limits) }

    /// A shutter time the allocation itself could have chosen: whole mains periods, within limits.
    /// Anything else (e.g. a manual value from before Smart Auto) is re-split at the next correction.
    static func isFlickerSafe(_ time: Int, period: Double, _ limits: ExposureLimits) -> Bool {
        let periods = Double(time) / period
        return time <= limits.maxTime && periods >= 1 && abs(periods - periods.rounded()) * period < 1
    }

    /// Reaches `ev` with gain alone at a fixed shutter time, or nil when gain cannot.
    static func setting(forEV ev: Double, time: Int, _ limits: ExposureLimits) -> ExposureSetting? {
        let remaining = ev - log2(Double(max(time, 1)))
        guard remaining >= 0 else { return nil }
        let gain = Double(limits.gain.lowerBound) + limits.gainUnit * (pow(2, remaining) - 1)
        guard gain <= Double(limits.maxGain) else { return nil }
        return ExposureSetting(time: time, gain: Int(gain.rounded()))
    }

    /// Spends exposure on shutter time first, then gain.
    static func setting(forEV ev: Double, _ limits: ExposureLimits) -> ExposureSetting {
        var time = min(pow(2, ev), Double(limits.maxTime))
        if let period = limits.flickerPeriod, time >= period {
            time = (time / period).rounded(.down) * period
        }
        time = min(max(time.rounded(), Double(limits.time.lowerBound)), Double(limits.time.upperBound))
        let remaining = max(ev - log2(time), 0)
        let gain = Double(limits.gain.lowerBound) + limits.gainUnit * (pow(2, remaining) - 1)
        return ExposureSetting(time: Int(time), gain: Int(min(gain, Double(limits.maxGain)).rounded()))
    }
}
