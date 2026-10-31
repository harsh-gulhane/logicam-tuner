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
/// - Corrections fade in over a few frames instead of landing in one, which looks like a flash on a call.
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
    /// Errors are averaged over about a second (five analysed frames), and over at least two frames
    /// after each change. Beside a window, a face brightens and darkens by 0.3 to 0.8 EV as the head turns
    /// and the face box jitters; acting on single frames made one correction set off the next.
    static let smoothing = 0.3
    static let samplesAfterChange = 2
    /// How far the measured brightness moves per EV of exposure change the model predicts. Camera tone
    /// curves exaggerate changes and gain units mean something different on every camera: a StreamCam
    /// moved 1.5 to 2.5 times as far as predicted, so each half-error correction overshot and the next
    /// one undid it. Learning it per correction failed: corrections are set off by the largest errors, which
    /// often include a passing misreading of the face, and that made the camera look far more responsive.
    static let response = 2.0
    /// Share of the error each correction removes on a camera that responds as `response` says. On
    /// cameras that respond 1 to 2.8 times the model, a correction then removes 45 to 125% of the error:
    /// at worst one small overshoot, never a cycle.
    static let correctionShare = 0.9
    /// Largest brightness change per frame while a correction fades in, in measured EV, and the most
    /// frames a fade takes.
    static let fadeStep = 0.03
    static let maxFadeFrames = 20

    public private(set) var isCorrecting = false
    /// The most recent smoothed error in EV.
    public private(set) var lastError = 0.0
    private var smoothedError: Double?
    private var samples = 0

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
        samples += 1
        // The mean of the frames since the last change, then a running average.
        let error = smoothedError.map { $0 + (raw - $0) * max(Self.smoothing, 1 / Double(samples)) } ?? raw
        smoothedError = error
        lastError = error
        // A setting from before Smart Auto may break the limits (e.g. a 1/5 s manual shutter that
        // costs frame rate); move it inside them even when brightness already looks right.
        let outsideLimits = current.time > limits.maxTime || current.gain > limits.maxGain
        guard outsideLimits || samples >= Self.samplesAfterChange else { return nil }
        if !outsideLimits, abs(error) < (isCorrecting ? Self.stopThreshold : Self.startThreshold) {
            isCorrecting = false
            return nil
        }
        isCorrecting = true
        // Most of the error per step, allowing for the camera's response so the step does not overshoot;
        // at most +1 or -1.5 EV at a time.
        let step = min(max(Self.correctionShare * error / Self.response, -1.5), 1.0)
        let ev = Self.ev(current, limits) + step
        var next = Self.setting(forEV: ev, limits)
        if let period = limits.flickerPeriod, next.time != current.time, abs(error) < Self.shutterStepThreshold,
           Self.isFlickerSafe(current.time, period: period, limits),
           let gainOnly = Self.setting(forEV: ev, time: current.time, limits) {
            next = gainOnly
        }
        guard next != current else { return nil }
        // The next frames show the new exposure.
        smoothedError = nil
        samples = 0
        return next
    }

    /// The settings that take exposure from `current` to `next` one frame at a time, ending on `next`.
    /// A correction that lands in one frame looks like a flash to the people on a call; steps of
    /// `fadeStep` measured EV look like the light changing.
    ///
    /// The fade runs on gain at the longer of the two shutter times, so the shutter changes at most once:
    /// at the start when exposure grows, at the end when it shrinks. Trading shutter for gain is never
    /// seamless, since the gain model is approximate (on a StreamCam, settings it rated equal differed by up
    /// to 20 levels of 255), and re-splitting exposure at every step made a long fade jump several times.
    public static func fade(from current: ExposureSetting, to next: ExposureSetting, limits: ExposureLimits) -> [ExposureSetting] {
        let from = Self.ev(current, limits), to = Self.ev(next, limits)
        let frames = min(max(Int((abs(to - from) * Self.response / Self.fadeStep).rounded(.up)), 1), Self.maxFadeFrames)
        let longer = max(current.time, next.time), shorter = min(current.time, next.time)
        var steps: [ExposureSetting] = []
        for frame in 1..<frames {
            let ev = from + (to - from) * Double(frame) / Double(frames)
            let step = Self.setting(forEV: ev, time: longer, limits) ?? Self.setting(forEV: ev, time: shorter, limits)
                ?? Self.setting(forEV: ev, limits)
            if step != (steps.last ?? current), step != next { steps.append(step) }
        }
        return steps + [next]
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
/// its brightness relative to the scene for a few seconds and then fades out; a new face fades in,
/// so a one-off false detection barely moves exposure.
///
/// The face is measured only on frames that face detection just ran on: on later frames a moving head
/// has left its box, which then covers hair or the window behind it and read 1 to 2 EV off. In between,
/// and while it is missed, the face keeps its brightness relative to the scene, averaged over the last
/// few detections.
public struct FaceMetering: Sendable {
    /// Seconds a missed face keeps its weight. Beside a window the face and the scene want exposures
    /// more than 1 EV apart, so looking down at notes for a few seconds swung exposure to the window and back.
    static let hold = 8.0
    static let fadeIn = 1.0
    static let fadeOut = 3.0
    /// Share of each new reading in the face's brightness relative to the scene.
    static let smoothing = 0.5

    /// How much the face counts, from 0 (scene only) to 1.
    public private(set) var weight = 0.0
    private var lastSeen = -Double.infinity
    private var lastDetection: Double?
    /// Face luminance over scene luminance.
    private var ratio: Double?

    public init() {}

    /// Returns `stats` with the face's luminance from its brightness relative to the scene. `detected` says
    /// whether face detection ran on this frame, so `stats.faceLuminance` is a fresh reading or a miss.
    /// `time` is in seconds.
    public mutating func update(_ stats: FrameStatistics, detected: Bool, at time: Double) -> FrameStatistics {
        var stats = stats
        if detected {
            // The first detection counts as a full fade, so metering starts on a face already in view.
            let elapsed = lastDetection.map { min(max(time - $0, 0), 1) } ?? Self.fadeIn
            lastDetection = time
            if let face = stats.faceLuminance, face > 0, stats.sceneLuminance > 0 {
                lastSeen = time
                let reading = face / stats.sceneLuminance
                ratio = ratio.map { $0 * pow(reading / $0, Self.smoothing) } ?? reading
                weight = min(weight + elapsed / Self.fadeIn, 1)
            } else if time - lastSeen > Self.hold {
                weight = max(weight - elapsed / Self.fadeOut, 0)
                if weight == 0 { ratio = nil }
            }
        }
        stats.faceLuminance = ratio.map { stats.sceneLuminance * $0 }
        return stats
    }
}
