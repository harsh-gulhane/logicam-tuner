import AVFoundation
import CoreMediaIO
import CoreVideo

extension CameraInfo {
    /// The AVFoundation device for this USB camera. AVFoundation's modelID embeds
    /// "VendorID_<dec> ProductID_<dec>" and its uniqueID embeds the USB location ID in hex.
    public func captureDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
                                                       position: .unspecified).devices
        let model = "VendorID_\(vendorID) ProductID_\(productID)"
        let location = String(format: "%x", locationID)
        return devices.first { $0.modelID.contains(model) && $0.uniqueID.lowercased().contains(location) }
            ?? devices.first { $0.modelID.contains(model) }
    }
}

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
    private let lock = NSLock()
    private var _preferredFrameRate = 30.0
    private var frameTimes: [Double] = []
    private let queue = DispatchQueue(label: "logicam.feed")
    private let output = AVCaptureVideoDataOutput()
    private var displayLayers: [AVSampleBufferDisplayLayer] = []

    public init?(_ camera: CameraInfo) {
        guard let device = camera.captureDevice(), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
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

    /// Whether any process, including this one, is streaming from the camera.
    ///
    /// `AVCaptureDevice.isInUseByAnotherApplication` stayed false on macOS 27 while other apps streamed
    /// from a StreamCam, so this asks CoreMediaIO, which reports streaming by any client.
    public var isStreamingSomewhere: Bool {
        // Looked up on each call (a few cheap property reads) so replugging and threads need no care.
        guard let object = Self.cmioObject(uniqueID: device.uniqueID) else { return false }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var running: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, 4, &used, &running) == 0 else { return false }
        return running != 0
    }

    static func cmioObject(uniqueID: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return nil }
        var objects = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &size, &objects) == 0 else { return nil }
        return objects.first { object in
            var uidAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(object, &uidAddress, 0, nil,
                                                   UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &uid)
            guard status == 0, let value = uid?.takeRetainedValue() else { return false }
            return value as String == uniqueID
        }
    }

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
            if locked, !isStreamingSomewhere, let (format, frameDuration) = Self.videoFormat(device, frameRate: preferredFrameRate) {
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

    /// The largest format up to 1080p that reaches `frameRate`, with the matching frame duration.
    /// Cameras such as the StreamCam list each rate as its own fixed range, often on separate formats.
    static func videoFormat(_ device: AVCaptureDevice, frameRate: Double) -> (AVCaptureDevice.Format, CMTime)? {
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMTime, Int32)? in
            let d = format.formatDescription.dimensions
            guard d.width <= 1920, let range = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= frameRate + 0.5 && $0.maxFrameRate >= frameRate - 0.5
            }) else { return nil }
            let duration = range.minFrameRate == range.maxFrameRate ? range.minFrameDuration
                : CMTime(value: 1000, timescale: CMTimeScale(frameRate * 1000))
            return (format, duration, d.width * d.height)
        }
        return candidates.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
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
            lock.withLock { frameTimes = [] }
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
        let layers = lock.withLock { () -> [AVSampleBufferDisplayLayer] in
            frameTimes.append(time)
            frameTimes.removeAll { $0 < time - 1 }
            return displayLayers
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
