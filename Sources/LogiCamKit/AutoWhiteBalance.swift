import Foundation

/// Feedback white balance driven by near-neutral surfaces instead of the whole frame.
///
/// Firmware AWB on many webcams averages the whole picture, so a coloured shirt or wall pulls the
/// picture the other way and it drifts during a call. This controller:
/// - looks only at near-grey, well-exposed pixels outside faces;
/// - holds the current setting when it cannot find enough of them, rather than guessing;
/// - corrects in mired (perceptually even) steps with hysteresis, so it settles and stays put.
public struct WhiteBalanceController: Sendable {
    /// Desired warmth of neutral surfaces in log-chroma units; positive renders whites slightly warm.
    public var warmthBias: Double = 0
    /// Where the analyzer should look for neutral pixels next.
    public private(set) var searchCenter = Chroma.neutral
    public private(set) var isCorrecting = false
    private var smoothedError: Double?

    static let startThreshold = 0.035
    static let stopThreshold = 0.012
    /// Mired change per unit of warmth error. Measured on a StreamCam, one unit of warmth took
    /// 90 to 200 mired depending on the range; using the low end means steps undershoot, never overshoot.
    static let miredPerWarmth = 100.0

    public init() {}

    /// Returns a new white-balance temperature in kelvin when it should change.
    public mutating func update(_ stats: FrameStatistics, currentKelvin: Int, range: ClosedRange<Int>) -> Int? {
        guard let cast = stats.neutralCast else {
            // No neutrals near the expected cast: move the search window toward the frame average
            // so a large cast can be found, but do not change white balance on that evidence.
            searchCenter = Self.blend(searchCenter, stats.averageCast, 0.3)
            smoothedError = nil
            isCorrecting = false
            return nil
        }
        searchCenter = Self.blend(searchCenter, cast, 0.5)
        let raw = cast.warmth - warmthBias
        let error = smoothedError.map { 0.6 * $0 + 0.4 * raw } ?? raw
        smoothedError = error
        if abs(error) < (isCorrecting ? Self.stopThreshold : Self.startThreshold) {
            isCorrecting = false
            return nil
        }
        isCorrecting = true
        // Too warm (amber) means the camera assumes bluer light than there is: lower the temperature.
        let mired = 1e6 / Double(max(currentKelvin, 1))
        let step = min(max(error * Self.miredPerWarmth, -40), 40)
        let kelvin = Int((1e6 / max(mired + step, 1)).rounded())
        let next = min(max(kelvin, range.lowerBound), range.upperBound)
        guard abs(next - currentKelvin) >= 10 else { return nil }
        smoothedError = nil
        return next
    }

    static func blend(_ a: Chroma, _ b: Chroma, _ t: Double) -> Chroma {
        Chroma(warmth: min(max(a.warmth + (b.warmth - a.warmth) * t, -0.6), 0.6),
               tint: min(max(a.tint + (b.tint - a.tint) * t, -0.15), 0.15))
    }
}
