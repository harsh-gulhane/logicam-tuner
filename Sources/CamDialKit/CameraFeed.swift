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
/// changes what that app receives. Frames are scaled down for analysis only.
public final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    public let device: AVCaptureDevice
    /// Called on the feed's queue with each analysis-sized BGRA frame.
    public var onFrame: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "camdial.feed")
    private let output = AVCaptureVideoDataOutput()

    public init?(_ camera: CameraInfo, analysisWidth: Int = 256) {
        guard let device = camera.captureDevice(), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.device = device
        self.input = input
        super.init()
        let dimensions = device.activeFormat.formatDescription.dimensions
        let aspect = dimensions.width > 0 ? Double(dimensions.height) / Double(dimensions.width) : 9.0 / 16
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: analysisWidth,
            kCVPixelBufferHeightKey as String: Int((Double(analysisWidth) * aspect).rounded()),
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
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
            if locked, !isStreamingSomewhere, let (format, frameDuration) = Self.videoFormat(device) {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = frameDuration
            }
            session.beginConfiguration()
            if session.inputs.isEmpty, session.canAddInput(input) { session.addInput(input) }
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    /// The largest format up to 1080p that reaches 30 fps, with its 30 fps frame duration.
    static func videoFormat(_ device: AVCaptureDevice) -> (AVCaptureDevice.Format, CMTime)? {
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMTime, Int32)? in
            let d = format.formatDescription.dimensions
            guard d.width <= 1920, let range = format.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= 29.9 })
            else { return nil }
            let duration = range.minFrameRate <= 30 && range.maxFrameRate >= 30 ? CMTime(value: 1, timescale: 30) : range.minFrameDuration
            return (format, duration, d.width * d.height)
        }
        return candidates.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    public func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let onFrame, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(buffer)
    }
}
