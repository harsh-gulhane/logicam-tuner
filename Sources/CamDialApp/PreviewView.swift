import AVFoundation
import SwiftUI

/// Live preview of the selected camera's shared capture session. The app model starts and stops
/// the session; some cameras apply settings only while streaming, so the preview also helps verify changes.
struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let layer = view.layer as? AVCaptureVideoPreviewLayer, layer.session !== session { layer.session = session }
    }
}
