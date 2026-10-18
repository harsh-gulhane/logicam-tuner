import CoreMedia

/// What a camera's image pipeline reports with each frame. Apple cameras (the Mac's built-in camera,
/// Continuity Camera) attach the exposure and colour their automatics chose; UVC cameras attach none,
/// so their values come from the camera's controls instead.
///
/// The keys are not documented by Apple and may change, so each value is optional.
public struct FrameMetadata: Equatable, Sendable {
    /// Shutter time in seconds.
    public var exposureTime: Double?
    public var iso: Double?
    /// Colour temperature white balance settled on, in kelvin.
    public var colorTemperature: Int?
    /// The camera's estimate of the scene's light level, in lux.
    public var lux: Int?

    public init(exposureTime: Double? = nil, iso: Double? = nil, colorTemperature: Int? = nil, lux: Int? = nil) {
        self.exposureTime = exposureTime
        self.iso = iso
        self.colorTemperature = colorTemperature
        self.lux = lux
    }

    /// Parses the frame's "MetadataDictionary" attachment; nil when it holds none of the known values.
    public init?(_ dictionary: [String: Any]) {
        func number(_ key: String) -> Double? { (dictionary[key] as? NSNumber)?.doubleValue.nonNegativeFinite }
        self.init(exposureTime: number("ExposureTime").flatMap { $0 > 0 ? $0 : nil }, iso: number("ISOSpeedRating"),
                  colorTemperature: number("CCT").map { Int($0.rounded()) }, lux: number("LuxLevel").map { Int($0.rounded()) })
        if self == FrameMetadata() { return nil }
    }

    public init?(_ sampleBuffer: CMSampleBuffer) {
        guard let dictionary = CMGetAttachment(sampleBuffer, key: "MetadataDictionary" as CFString,
                                               attachmentModeOut: nil) as? [String: Any] else { return nil }
        self.init(dictionary)
    }
}

private extension Double {
    var nonNegativeFinite: Double? { isFinite && self >= 0 ? self : nil }
}
