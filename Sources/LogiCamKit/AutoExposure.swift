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
    /// Longest exposure that keeps the stream's frame rate.
    public var frameTime: Int
    /// Longest exposure allowed; longer than `frameTime` when low light may lower the frame rate.
    public var maxTime: Int
    /// Highest gain the user accepts; more gain means more noise.
    public var maxGain: Int
    /// Mains flicker period in exposure units (100 at 50 Hz, 83.3 at 60 Hz), nil when anti-flicker is off.
    public var flickerPeriod: Double?

    public init(time: ClosedRange<Int>, gain: ClosedRange<Int>, frameTime: Int? = nil, maxTime: Int, maxGain: Int,
                flickerPeriod: Double?) {
        self.time = time
        self.gain = gain
        self.maxTime = min(max(maxTime, time.lowerBound), time.upperBound)
        self.frameTime = min(max(frameTime ?? maxTime, time.lowerBound), self.maxTime)
        self.maxGain = min(max(maxGain, gain.lowerBound), gain.upperBound)
        self.flickerPeriod = flickerPeriod
    }

    /// The camera does not report what its gain units mean; the controller assumes the full range is
    /// about +3 EV (8x). Feedback corrects any error, it only affects how quickly exposure converges.
    var gainUnit: Double { max(Double(gain.upperBound - gain.lowerBound), 1) / 8 }

    /// Gain used at the stream's frame rate before frames get longer: half the allowed gain. Lowering
    /// the frame rate first made every call in a dim room run at 15 fps, which looks choppy.
    var gainBeforeLongerFrames: Int { gain.lowerBound + (maxGain - gain.lowerBound) / 2 }
}

/// Feedback auto-exposure that meters faces first and changes exposure only when the error is
/// clearly visible, so the picture does not "breathe" while someone talks or moves.
///
/// Differences from typical webcam firmware AE:
/// - Face priority: a backlit face is exposed for the face, not the window behind it.
/// - Hysteresis: corrections start at a 0.25 EV error and stop at 0.08 EV.
/// - Prefers shutter time over gain, so the image stays as clean as the frame rate allows, and gain
///   over a lower frame rate, so video stays smooth.
/// - Snaps shutter time to whole mains periods so artificial light does not band.
public struct ExposureController: Sendable {
    /// Exposure compensation in EV.
    public var bias: Double = 0
    public var facePriority = true
    /// How much detected faces count, from 0 (scene only) to 1; see `FaceMetering`.
    public var faceWeight = 1.0
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
        // Without a face, hold back when a lot of the centre is blown out.
        let sceneError = stats.clippedFraction > 0.03 ? min(scene, 0) - min(1, (stats.clippedFraction - 0.03) * 8) : scene
        guard facePriority, faceWeight > 0, let face = stats.faceLuminance else { return sceneError + bias }
        // Mostly the face, with some scene so the background is not thrown away entirely.
        let faceError = 0.65 * ev(Self.faceTarget, face) + 0.35 * scene
        return faceWeight * faceError + (1 - faceWeight) * sceneError + bias
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
        log2(Double(max(setting.time, 1))) + gainEV(setting.gain, limits)
    }

    /// log2 of the exposure a gain setting adds.
    static func gainEV(_ gain: Int, _ limits: ExposureLimits) -> Double {
        log2(1 + Double(max(gain - limits.gain.lowerBound, 0)) / limits.gainUnit)
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

    /// Spends exposure on shutter time up to the stream's frame time, then on gain up to
    /// `gainBeforeLongerFrames`, then on longer frames where allowed, and on the rest of the gain last.
    static func setting(forEV ev: Double, _ limits: ExposureLimits) -> ExposureSetting {
        var time = shutter(pow(2, ev), upTo: limits.frameTime, limits)
        let moderateGain = gainEV(limits.gainBeforeLongerFrames, limits)
        if limits.maxTime > limits.frameTime, ev - log2(time) > moderateGain {
            time = max(time, shutter(pow(2, ev - moderateGain), upTo: limits.maxTime, limits))
        }
        let remaining = max(ev - log2(time), 0)
        let gain = Double(limits.gain.lowerBound) + limits.gainUnit * (pow(2, remaining) - 1)
        return ExposureSetting(time: Int(time), gain: Int(min(gain, Double(limits.maxGain)).rounded()))
    }

    /// The longest shutter time up to `wanted` and `cap`: whole mains periods with anti-flicker, within
    /// the camera's range. Periods are matched to within one 100 µs unit, so two 60 Hz periods (16.67 ms)
    /// fit a 60 fps frame of 166 units.
    static func shutter(_ wanted: Double, upTo cap: Int, _ limits: ExposureLimits) -> Double {
        var time = min(wanted, Double(cap))
        if let period = limits.flickerPeriod, time + 1 >= period {
            time = min(((time + 1) / period).rounded(.down) * period, Double(cap))
        }
        return min(max(time.rounded(), Double(limits.time.lowerBound)), Double(limits.time.upperBound))
    }
}

/// Keeps face metering steady while face detection comes and goes.
///
/// Vision misses a face for a moment when it turns, looks down or is dimly lit. Switching between face
/// and scene metering on every miss moved the exposure target by 0.3 EV or more, past the correction
/// threshold, so each miss and each return caused a visible correction. A missed face is assumed to keep
/// its last brightness relative to the scene for a few seconds and then fades out; a new face fades in,
/// so a one-off false detection barely moves exposure.
public struct FaceMetering: Sendable {
    /// Seconds a missed face keeps its weight.
    static let hold = 4.0
    static let fadeIn = 1.0
    static let fadeOut = 2.0

    /// How much the face counts, from 0 (scene only) to 1.
    public private(set) var weight = 0.0
    private var lastSeen = -Double.infinity
    private var lastUpdate: Double?
    /// Face luminance over scene luminance when the face was last measured.
    private var ratio: Double?

    public init() {}

    /// Returns `stats` with the face's luminance estimated while it is missed. `time` is in seconds.
    public mutating func update(_ stats: FrameStatistics, at time: Double) -> FrameStatistics {
        var stats = stats
        // The first frame counts as a full fade, so metering starts on a face already in view.
        let elapsed = lastUpdate.map { min(max(time - $0, 0), 1) } ?? Self.fadeIn
        lastUpdate = time
        if let face = stats.faceLuminance, stats.sceneLuminance > 0 {
            lastSeen = time
            ratio = face / stats.sceneLuminance
            weight = min(weight + elapsed / Self.fadeIn, 1)
        } else if time - lastSeen > Self.hold {
            weight = max(weight - elapsed / Self.fadeOut, 0)
            if weight == 0 { ratio = nil }
        }
        if stats.faceLuminance == nil, let ratio { stats.faceLuminance = stats.sceneLuminance * ratio }
        return stats
    }
}
