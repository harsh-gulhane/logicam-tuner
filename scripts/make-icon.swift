// Renders LogiCam Tuner's app icon and logo (a PNG, 1024 px unless a size is given) with AppKit; used by
// build-app.sh and for docs/images/logo.png. A camera lens inside a tuning dial, drawn from plain paths.
//
//   swift scripts/make-icon.swift <output.png> [size]
import AppKit

let output = CommandLine.arguments[1]
let pixels = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let size = 1024.0

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func circle(_ center: NSPoint, _ radius: Double) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

func point(_ center: NSPoint, _ radius: Double, degrees: Double) -> NSPoint {
    NSPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: the shape fills about 80% of the canvas.
    let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
    NSGradient(colors: [color(0.13, 0.47, 0.98), color(0.36, 0.20, 0.86)])!.draw(in: shape, angle: -90)

    let center = NSPoint(x: 512, y: 500)
    // The dial: a track open at the bottom, with the part up to the knob filled in.
    let dialRadius = 300.0
    let start = 225.0, end = -45.0, knob = 30.0
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: dialRadius, startAngle: start, endAngle: end, clockwise: true)
    track.lineWidth = 26
    track.lineCapStyle = .round
    color(1, 1, 1, 0.28).setStroke()
    track.stroke()
    let value = NSBezierPath()
    value.appendArc(withCenter: center, radius: dialRadius, startAngle: start, endAngle: knob, clockwise: true)
    value.lineWidth = 26
    value.lineCapStyle = .round
    NSColor.white.setStroke()
    value.stroke()
    let knobCenter = point(center, dialRadius, degrees: knob)
    NSColor.white.setFill()
    circle(knobCenter, 44).fill()
    color(0.22, 0.36, 0.94).setFill()
    circle(knobCenter, 18).fill()

    // The lens: white body, dark barrel, blue glass and a highlight.
    NSColor.white.setFill()
    circle(center, 220).fill()
    NSGradient(colors: [color(0.16, 0.18, 0.32), color(0.03, 0.04, 0.10)])!.draw(in: circle(center, 168), angle: -90)
    NSGradient(colors: [color(0.30, 0.55, 1.0), color(0.10, 0.12, 0.45)])!
        .draw(in: circle(center, 100), relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
    color(1, 1, 1, 0.75).setFill()
    circle(NSPoint(x: center.x - 38, y: center.y + 42), 26).fill()
    color(1, 1, 1, 0.35).setFill()
    circle(NSPoint(x: center.x + 40, y: center.y - 34), 11).fill()
    return true
}
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
