import AVFoundation
import CamDialKit
import SwiftUI

/// Live preview of the selected camera, matched by USB vendor/product ID and location.
/// Some cameras apply settings only while streaming, so the preview also helps verify changes.
struct PreviewView: NSViewRepresentable {
    let camera: CameraInfo

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView() }

    func updateNSView(_ view: PreviewNSView, context: Context) { view.show(camera) }

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) { view.stop() }
}

final class PreviewNSView: NSView {
    private let session = AVCaptureSession()
    private var shownID: UInt64?
    private let queue = DispatchQueue(label: "camdial.preview")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        layer = preview
    }

    required init?(coder: NSCoder) { nil }

    func show(_ camera: CameraInfo) {
        guard shownID != camera.id else { return }
        shownID = camera.id
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.start(camera) }
        }
    }

    private func start(_ camera: CameraInfo) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        // AVFoundation's modelID embeds "VendorID_<dec> ProductID_<dec>"; uniqueID embeds the location ID in hex.
        let model = "VendorID_\(camera.vendorID) ProductID_\(camera.productID)"
        let location = String(format: "%x", camera.locationID)
        let device = devices.first { $0.modelID.contains(model) && $0.uniqueID.lowercased().contains(location) }
            ?? devices.first { $0.modelID.contains(model) }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }

    func stop() { queue.async { [session] in session.stopRunning() } }
}
