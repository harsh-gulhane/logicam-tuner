import AVFoundation
import CoreVideo

/// One capture session for a camera, shared by the live preview and Smart Auto.
///
/// When another app is already streaming, the session uses the device's active format so it never
/// changes what that app receives.
///
/// One full-resolution output in the camera's native format feeds both the previews
/// (`AVSampleBufferDisplayLayer`s) and Smart Auto, which samples frames in place. A separate scaled
/// analysis output cost a scaled copy of every frame, and `AVCaptureVideoPreviewLayer` in a session
/// with that output showed a visibly low-resolution picture of a 1080p stream.
public final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    public let camera: VideoCamera
    public let device: AVCaptureDevice
    /// Called on the feed's queue with each full-resolution frame; return quickly.
    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// Diagnostic messages, called on the feed's queue.
    public var onLog: ((String) -> Void)?
    /// Frame rate to ask for when LogiCam Tuner is the only client. Another app's stream is never changed.
    public var preferredFrameRate: Double {
        get { lock.withLock { _preferredFrameRate } }
        set { lock.withLock { _preferredFrameRate = newValue } }
    }
    /// Frames per second actually delivered over the last second or so; 0 when not streaming.
    public var measuredFrameRate: Double { lock.withLock { frameTimes.count > 1 ? Double(frameTimes.count - 1) / max(frameTimes.last! - frameTimes.first!, 1e-3) : 0 } }
    /// Exposure and colour the camera reported with a recent frame; nil for cameras that report none.
    public var metadata: FrameMetadata? { lock.withLock { _metadata } }
    private let lock = NSLock()
    private var _preferredFrameRate = 30.0
    private var frameTimes: [Double] = []
    private var _metadata: FrameMetadata?
    private var metadataTime = -Double.infinity
    private let queue = DispatchQueue(label: "logicam.feed")
    private let output = AVCaptureVideoDataOutput()
    private var displayLayers: [AVSampleBufferDisplayLayer] = []

    public init?(_ camera: VideoCamera) {
        guard let device = camera.captureDevice(), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.camera = camera
        self.device = device
        self.input = input
        super.init()
        // The camera's native bi-planar format, unscaled: no conversion before display or analysis.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                               queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onLog?("capture session error: \(error.map { "\($0)" } ?? "unknown")")
        }
    }

    private let input: AVCaptureDeviceInput

    public var isRunning: Bool { session.isRunning }

    /// Whether this process is streaming from the camera (any session, not just this feed's).
    public var isStreamingInThisProcess: Bool { camera.isStreamingInThisProcess }

    /// Whether any process, including this one, is streaming from the camera.
    public var isStreamingSomewhere: Bool { camera.isStreamingSomewhere }

    /// Current frame duration in seconds, which bounds the longest useful shutter time.
    public var frameDuration: Double {
        let seconds = device.activeVideoMinFrameDuration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 1.0 / 30
    }

    /// Starts streaming. The device stays locked for configuration while the session starts, which
    /// on macOS stops the session from choosing a format to suit its small analysis output. If another
    /// client is streaming, its format is left exactly as it is; otherwise a normal video mode is chosen
    /// (the camera's idle default can be a slow full-sensor mode).
    public func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            let locked = (try? device.lockForConfiguration()) != nil
            defer { if locked { device.unlockForConfiguration() } }
            // Cameras such as the Mac's built-in one stop at 30 fps.
            if locked, !isStreamingSomewhere, let (format, frameDuration) = Self.videoFormat(device, frameRate: preferredFrameRate)
                ?? Self.videoFormat(device, frameRate: 30) {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = frameDuration
            }
            session.beginConfiguration()
            if session.inputs.isEmpty, session.canAddInput(input) { session.addInput(input) }
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            if !session.isRunning { onLog?("capture session did not start") }
        }
    }

    /// The largest format up to 1080p that reaches `frameRate`, with the matching frame duration,
    /// preferring 16:9 (the Mac's built-in camera also offers larger 4:3, square and portrait modes).
    /// Cameras such as the StreamCam list each rate as its own fixed range, often on separate formats.
    static func videoFormat(_ device: AVCaptureDevice, frameRate: Double) -> (AVCaptureDevice.Format, CMTime)? {
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMTime, Bool, Int32, Double)? in
            let d = format.formatDescription.dimensions
            guard d.width <= 1920, let range = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= frameRate + 0.5 && $0.maxFrameRate >= frameRate - 0.5
            }) else { return nil }
            let duration = range.minFrameRate == range.maxFrameRate ? range.minFrameDuration
                : CMTime(value: 1000, timescale: CMTimeScale(frameRate * 1000))
            let fastest = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return (format, duration, d.width * 9 == d.height * 16, d.width * d.height, fastest)
        }
        // 16:9, then the largest picture; among equals, the format that can run fastest (on the
        // StreamCam the compressed 420v modes, which need less USB bandwidth than uncompressed yuvs).
        return candidates.max { ($0.2 ? 1 : 0, $0.3, $0.4) < ($1.2 ? 1 : 0, $1.3, $1.4) }.map { ($0.0, $0.1) }
    }

    /// Switches the camera to a smoother mode while another app is streaming, e.g. when an app picked
    /// the StreamCam's 2304×1296 mode, which only runs at 5 fps. The format is device-wide, so the
    /// other app receives the new frames (after a pause of about a second). Only modes with the same
    /// aspect ratio are considered, so the picture is not reshaped. Returns the new mode, or nil when
    /// nothing better exists or the device could not be configured.
    @discardableResult
    public func upgradeSharedFormat(frameRate: Double) -> CMVideoDimensions? {
        let current = dimensions
        guard current.width > 0, configuredFrameRate < frameRate - 0.5,
              let (format, duration) = Self.videoFormat(device, frameRate: frameRate) else { return nil }
        let next = format.formatDescription.dimensions
        // Same shape: width × height ratio within 1%.
        guard abs(Double(next.width) * Double(current.height) - Double(next.height) * Double(current.width))
                < 0.01 * Double(current.width) * Double(current.height),
              (try? device.lockForConfiguration()) != nil else { return nil }
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        return next
    }

    /// Resolution of the stream the camera is delivering. The format is device-wide, so this is also
    /// what another app streaming from the camera has configured.
    public var dimensions: CMVideoDimensions { device.activeFormat.formatDescription.dimensions }

    /// The frame rate the active configuration asks for. Long exposures with auto-exposure priority
    /// can deliver fewer frames; see `measuredFrameRate`.
    public var configuredFrameRate: Double { 1 / frameDuration }

    /// FourCC of the active format, e.g. "420v" or "yuvs".
    public var pixelFormat: String {
        let code = device.activeFormat.formatDescription.mediaSubType.rawValue
        return String(bytes: withUnsafeBytes(of: code.bigEndian, Array.init), encoding: .ascii) ?? "?"
    }

    /// Restarts streaming so a new `preferredFrameRate` takes effect.
    public func restart() {
        guard isRunning else { return }
        stop()
        start()
    }

    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            lock.withLock { frameTimes = []; _metadata = nil; metadataTime = -.infinity }
        }
    }

    /// Shows full-resolution frames in `layer` until it is removed.
    public func addDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock { if !displayLayers.contains(layer) { displayLayers.append(layer) } }
    }

    public func removeDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock { displayLayers.removeAll { $0 === layer } }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let (layers, readMetadata) = lock.withLock { () -> ([AVSampleBufferDisplayLayer], Bool) in
            frameTimes.append(time)
            frameTimes.removeAll { $0 < time - 1 }
            return (displayLayers, time - metadataTime >= 0.25)
        }
        if readMetadata {
            let metadata = FrameMetadata(sampleBuffer)
            lock.withLock { _metadata = metadata; metadataTime = time }
        }
        if !layers.isEmpty {
            // Live video: show each frame as soon as it arrives rather than by its timestamp.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            for layer in layers {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sampleBuffer)
            }
        }
        guard let onFrame, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(buffer)
    }
}
