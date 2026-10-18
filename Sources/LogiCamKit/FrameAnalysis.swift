import CoreGraphics
import CoreVideo
import Foundation

/// A colour cast in log-chroma space. `warmth` > 0 means amber (more red than blue);
/// `tint` > 0 means green (more green than red and blue).
public struct Chroma: Equatable, Sendable {
    public var warmth: Double
    public var tint: Double

    public init(warmth: Double, tint: Double) {
        self.warmth = warmth
        self.tint = tint
    }

    public static let neutral = Chroma(warmth: 0, tint: 0)

    init(red: Double, green: Double, blue: Double) {
        let lr = log(red), lg = log(green), lb = log(blue)
        warmth = (lr - lb) / 2
        tint = lg - (lr + lb) / 2
    }
}

/// Measurements from one video frame that the automatic controllers act on.
public struct FrameStatistics: Equatable, Sendable {
    /// Centre-weighted geometric mean of linear luminance (0...1).
    public var sceneLuminance: Double
    /// Geometric mean of linear luminance inside detected faces, when any.
    public var faceLuminance: Double?
    /// Weighted share of pixels at or near full scale.
    public var clippedFraction: Double
    /// Mean cast of near-neutral pixels, nil when too few were found to be trustworthy.
    public var neutralCast: Chroma?
    /// Share of sampled pixels classified as near-neutral.
    public var neutralFraction: Double
    /// Mean cast of all well-exposed pixels ("grey world"). Only used to find neutrals, never to set white balance.
    public var averageCast: Chroma
}

/// Computes `FrameStatistics` from 8-bit video frames: BGRA, or the bi-planar YCbCr cameras deliver natively.
public enum FrameAnalyzer {
    /// sRGB transfer decoded once per code value.
    static let linear: [Double] = (0..<256).map { code in
        let c = Double(code) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Neutral pixels are searched for in a window around `searchCenter`, the cast the controller
    /// currently believes neutral surfaces have. Searching around the previous estimate lets the
    /// window follow a strong cast instead of rejecting every pixel. Faces are excluded from the
    /// colour estimate so skin does not pull white balance.
    public static func analyze(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                               faces: [CGRect] = [], searchCenter: Chroma = .neutral,
                               maxSamples: Int = 40_000) -> FrameStatistics {
        precondition(bytesPerRow >= width * 4 && bgra.count >= bytesPerRow * max(height - 1, 0) + width * 4)
        let base = bgra.baseAddress!
        return analyze(width: width, height: height, faces: faces, searchCenter: searchCenter, maxSamples: maxSamples) { x, y in
            let p = base + y * bytesPerRow + x * 4
            return (p.load(fromByteOffset: 2, as: UInt8.self), p.load(fromByteOffset: 1, as: UInt8.self),
                    p.load(fromByteOffset: 0, as: UInt8.self))
        }
    }

    /// Analyses a pixel buffer in BGRA or 8-bit bi-planar 4:2:0 YCbCr, sampling it
    /// in place so full-resolution frames need no scaled copy. Returns nil for other formats.
    public static func analyze(_ buffer: CVPixelBuffer, faces: [CGRect] = [], searchCenter: Chroma = .neutral,
                               maxSamples: Int = 40_000) -> FrameStatistics? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            return analyze(bgra: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height), width: width,
                           height: height, bytesPerRow: bytesPerRow, faces: faces, searchCenter: searchCenter,
                           maxSamples: maxSamples)
        }
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let ycbcr = YCbCr(bt601: matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String), fullRange: fullRange)
        return analyze(width: width, height: height, faces: faces, searchCenter: searchCenter, maxSamples: maxSamples) { x, y in
            let luma = lumaBase.load(fromByteOffset: y * lumaRow + x, as: UInt8.self)
            let c = chromaBase + (y / 2) * chromaRow + (x / 2) * 2
            return ycbcr.rgb(luma, c.load(fromByteOffset: 0, as: UInt8.self), c.load(fromByteOffset: 1, as: UInt8.self))
        }
    }

    /// 8-bit YCbCr to gamma-encoded RGB.
    struct YCbCr {
        let bt601: Bool
        let fullRange: Bool

        func rgb(_ y: UInt8, _ cb: UInt8, _ cr: UInt8) -> (UInt8, UInt8, UInt8) {
            let l = fullRange ? Double(y) : (Double(y) - 16) * 255 / 219
            let scale = fullRange ? 1.0 : 255.0 / 224
            let u = (Double(cb) - 128) * scale, v = (Double(cr) - 128) * scale
            let (r, g, b) = bt601
                ? (l + 1.402 * v, l - 0.344136 * u - 0.714136 * v, l + 1.772 * u)
                : (l + 1.5748 * v, l - 0.1873 * u - 0.4681 * v, l + 1.8556 * u)
            func clamp(_ x: Double) -> UInt8 { UInt8(min(max(x.rounded(), 0), 255)) }
            return (clamp(r), clamp(g), clamp(b))
        }
    }

    /// The shared measurement over sampled pixels; `pixel` returns gamma-encoded (r, g, b) at (x, y).
    static func analyze(width: Int, height: Int, faces: [CGRect], searchCenter: Chroma, maxSamples: Int,
                        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> FrameStatistics {
        let stride = max(1, Int((Double(width * height) / Double(maxSamples)).squareRoot().rounded(.up)))
        // Shrink face boxes slightly so hair and background at the edges do not count as face.
        let faceBoxes = faces.map { $0.insetBy(dx: $0.width * 0.1, dy: $0.height * 0.1) }
        var logSum = 0.0, weightSum = 0.0, clipped = 0.0
        var faceLogSum = 0.0, faceCount = 0.0
        var neutralR = 0.0, neutralG = 0.0, neutralB = 0.0, neutralWeight = 0.0
        var neutralCount = 0.0, samples = 0.0
        var allR = 0.0, allG = 0.0, allB = 0.0
        let floor = 1e-3

        for y in Swift.stride(from: 0, to: height, by: stride) {
            let ny = (Double(y) + 0.5) / Double(height)
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let (r8, g8, b8) = pixel(x, y)
                let r = linear[Int(r8)], g = linear[Int(g8)], b = linear[Int(b8)]
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let nx = (Double(x) + 0.5) / Double(width)
                // Centre weighting: a broad Gaussian so edges still count a little.
                let dx = nx - 0.5, dy = ny - 0.5
                let weight = exp(-(dx * dx + dy * dy) / (2 * 0.28 * 0.28))
                logSum += weight * log(luminance + floor)
                weightSum += weight
                if max(r8, g8, b8) >= 250 { clipped += weight }
                samples += 1

                let inFace = faceBoxes.contains { $0.contains(CGPoint(x: nx, y: ny)) }
                if inFace {
                    faceLogSum += log(luminance + floor)
                    faceCount += 1
                    continue
                }
                // Near-neutral candidates: well exposed, unclipped, and close to the search centre.
                guard luminance > 0.02, max(r8, g8, b8) < 245, min(r8, g8, b8) > 4 else { continue }
                allR += r; allG += g; allB += b
                let chroma = Chroma(red: r, green: g, blue: b)
                guard abs(chroma.warmth - searchCenter.warmth) < 0.22,
                      abs(chroma.tint - searchCenter.tint) < 0.18 else { continue }
                // Brighter neutral surfaces are the more reliable reference.
                let w = luminance
                neutralR += w * r; neutralG += w * g; neutralB += w * b
                neutralWeight += w
                neutralCount += 1
            }
        }

        let neutralFraction = samples > 0 ? neutralCount / samples : 0
        let cast: Chroma? = neutralFraction >= 0.03 && neutralWeight > 0
            ? Chroma(red: neutralR / neutralWeight, green: neutralG / neutralWeight, blue: neutralB / neutralWeight)
            : nil
        // A face needs enough samples to be measured rather than guessed.
        let faceLuminance = faceCount >= 12 ? max(exp(faceLogSum / faceCount) - floor, 0) : nil
        return FrameStatistics(
            sceneLuminance: weightSum > 0 ? max(exp(logSum / weightSum) - floor, 0) : 0,
            faceLuminance: faceLuminance,
            clippedFraction: weightSum > 0 ? clipped / weightSum : 0,
            neutralCast: cast,
            neutralFraction: neutralFraction,
            averageCast: allG > 0 ? Chroma(red: allR, green: allG, blue: allB) : .neutral
        )
    }
}
