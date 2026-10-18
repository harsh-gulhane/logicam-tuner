import Foundation
import IOKit
import IOKit.usb

/// Reports USB device arrivals and removals so callers can refresh their camera list.
/// The handler runs on the main queue; matching is broad because UVC filtering needs the interface tree.
public final class CameraMonitor {
    public enum Event: Sendable {
        case attached
        case detached
    }

    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let handler: (Event) -> Void

    public init(handler: @escaping (Event) -> Void) {
        self.handler = handler
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        subscribe(kIOFirstMatchNotification, event: .attached)
        subscribe(kIOTerminatedNotification, event: .detached)
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }

    private final class Context {
        let event: Event
        weak var monitor: CameraMonitor?
        init(event: Event, monitor: CameraMonitor) {
            self.event = event
            self.monitor = monitor
        }
    }

    private var contexts: [Context] = []

    private func subscribe(_ type: String, event: Event) {
        let context = Context(event: event, monitor: self)
        contexts.append(context)
        var iterator: io_iterator_t = 0
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        let status = IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostDevice"), { refcon, iterator in
            guard let refcon else { return }
            let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
            let changed = CameraMonitor.drain(iterator)
            if changed { context.monitor?.handler(context.event) }
        }, refcon, &iterator)
        guard status == KERN_SUCCESS else { return }
        iterators.append(iterator)
        // Arm the notification; the initial batch is the devices already attached.
        _ = Self.drain(iterator)
    }

    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var any = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            any = true
            IOObjectRelease(service)
        }
        return any
    }
}
