import AVFoundation
import SwiftUI

/// Live preview of the selected camera's shared capture session. The app model starts and stops
/// the session; one session can feed several previews (window and menu-bar panel).
struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    /// Show a mirror image, as video-call apps do for self-view.
    var mirrored = false

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(session: session) }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        if view.preview.session !== session { view.preview.session = session }
        view.mirrored = mirrored
    }
}

final class PreviewNSView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    var mirrored = false { didSet { if mirrored != oldValue { needsLayout = true } } }

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Mirror around the view's centre rather than the layer's origin.
        preview.transform = CATransform3DIdentity
        preview.frame = bounds
        if mirrored { preview.transform = CATransform3DMakeScale(-1, 1, 1) }
        CATransaction.commit()
    }
}
