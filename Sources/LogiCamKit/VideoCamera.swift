import AVFoundation
import CoreMediaIO

/// A camera macOS can stream from: a UVC camera such as the StreamCam, the Mac's built-in camera or a
/// Continuity Camera iPhone. Only UVC cameras have controls LogiCam Tuner can change; every camera has
/// a stream whose use, format and frame rate can be watched.
public struct VideoCamera: Hashable, Sendable, Identifiable {
    /// AVFoundation's uniqueID, which is also the CoreMediaIO device UID; "usb:…" for a UVC camera
    /// AVFoundation does not list.
    public let id: String
    public let name: String
    /// The USB identity, for UVC cameras.
    public let uvc: CameraInfo?
    public let isBuiltIn: Bool

    public init(id: String, name: String, uvc: CameraInfo?, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.uvc = uvc
        self.isBuiltIn = isBuiltIn
    }

    /// Every camera: UVC cameras first, then the Mac's own, then any others. Desk View cameras are
    /// left out; they are a crop of a camera already listed.
    public static func list() -> [VideoCamera] {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                       mediaType: .video, position: .unspecified).devices
        let usb = Camera.list().map { info in
            let device = info.captureDevice(in: devices)
            return VideoCamera(id: device?.uniqueID ?? "usb:" + info.persistentKey, name: info.name, uvc: info, isBuiltIn: false)
        }
        let others = devices.filter { device in !usb.contains { $0.id == device.uniqueID } }
            .map { VideoCamera(id: $0.uniqueID, name: $0.localizedName, uvc: nil, isBuiltIn: $0.deviceType == .builtInWideAngleCamera) }
            .sorted { $0.isBuiltIn && !$1.isBuiltIn }
        return usb + others
    }

    public func captureDevice() -> AVCaptureDevice? { AVCaptureDevice(uniqueID: id) }

    /// Which camera to watch next, or nil to stay on `selected`: the camera another app is using,
    /// else `chosen` (the user's pick). UVC cameras win when apps use several, since Smart Auto and
    /// controls only exist for them. `busy` holds the other cameras that other apps are using.
    public static func follow(selected: VideoCamera?, selectedInUse: Bool, busy: [VideoCamera],
                              chosen: VideoCamera?) -> VideoCamera? {
        let target = selectedInUse ? (selected?.uvc == nil ? busy.first { $0.uvc != nil } : nil)
            : busy.first { $0.uvc != nil } ?? busy.first ?? chosen
        return target == selected ? nil : target
    }

    /// Whether this process is streaming from the camera. It stays true for a second or so after the
    /// last session stops.
    public var isStreamingInThisProcess: Bool { flag(kCMIODevicePropertyDeviceIsRunning) }

    /// Whether any process, including this one, is streaming from the camera.
    ///
    /// `AVCaptureDevice.isInUseByAnotherApplication` stayed false on macOS 27 while other apps streamed
    /// from a StreamCam, so this asks CoreMediaIO, which reports streaming by any client.
    public var isStreamingSomewhere: Bool { flag(kCMIODevicePropertyDeviceIsRunningSomewhere) }

    private func flag(_ selector: Int) -> Bool {
        // Looked up on each call (a few cheap property reads) so replugging and threads need no care.
        guard let object = Self.cmioObject(uid: id) else { return false }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var running: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, 4, &used, &running) == 0 else { return false }
        return running != 0
    }

    private static func cmioObject(uid: String) -> CMIOObjectID? {
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
            var value: Unmanaged<CFString>?
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(object, &uidAddress, 0, nil,
                                                   UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
            guard status == 0, let value = value?.takeRetainedValue() else { return false }
            return value as String == uid
        }
    }
}

extension CameraInfo {
    /// The AVFoundation device for this USB camera. AVFoundation's modelID embeds
    /// "VendorID_<dec> ProductID_<dec>" and its uniqueID embeds the USB location ID in hex.
    func captureDevice(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let model = "VendorID_\(vendorID) ProductID_\(productID)"
        let location = String(format: "%x", locationID)
        return devices.first { $0.modelID.contains(model) && $0.uniqueID.lowercased().contains(location) }
            ?? devices.first { $0.modelID.contains(model) }
    }
}
