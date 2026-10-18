import AVFoundation
import CamDialKit
import SwiftUI

/// Live preview of the selected camera at the stream's full resolution. The app model starts and
/// stops the feed; one feed can drive several previews (window and menu-bar panel).
struct PreviewView: NSViewRepresentable {
    let feed: CameraFeed
    /// Show a mirror image, as video-call apps do for self-view.
    var mirrored = false

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView() }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.attach(to: feed)
        view.mirrored = mirrored
    }

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) { view.attach(to: nil) }
}

final class PreviewNSView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private weak var feed: CameraFeed?
    var mirrored = false { didSet { if mirrored != oldValue { needsLayout = true } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
    }

    required init?(coder: NSCoder) { nil }

    func attach(to feed: CameraFeed?) {
        guard feed !== self.feed else { return }
        self.feed?.removeDisplayLayer(display)
        display.flushAndRemoveImage()
        self.feed = feed
        feed?.addDisplayLayer(display)
    }

    /// Layers added by hand do not inherit the display's scale; match it so nothing is resampled twice.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        display.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Mirror around the view's centre rather than the layer's origin.
        display.transform = CATransform3DIdentity
        display.frame = bounds
        if mirrored { display.transform = CATransform3DMakeScale(-1, 1, 1) }
        CATransaction.commit()
    }
}
