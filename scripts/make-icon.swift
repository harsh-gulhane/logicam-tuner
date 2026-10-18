// Renders LogiCam Tuner's app icon (1024 px PNG) with AppKit; used by build-app.sh.
import AppKit

let size = 1024.0
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: the shape fills about 80% of the canvas.
    let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.86, alpha: 1)])!
        .draw(in: shape, angle: -90)
    let symbol = NSImage(systemSymbolName: "web.camera.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 430, weight: .regular))!
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 20, width: s.width, height: s.height))
    return true
}
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
