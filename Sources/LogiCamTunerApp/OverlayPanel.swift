import AppKit
import LogiCamKit
import SwiftUI

/// A small always-on-top panel showing the live stream. It never takes focus from the call app,
/// follows you across Spaces and full-screen apps, and can be dragged anywhere.
@MainActor
final class OverlayController {
    private let panel: NSPanel

    init(model: AppModel, monitor: LiveMonitor) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let host = NSHostingView(rootView: OverlayView(monitor: monitor).environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        if !panel.setFrameUsingName("LogiCamTunerOverlay"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 320, y: screen.maxY - 20))
        }
        panel.setFrameAutosaveName("LogiCamTunerOverlay")
    }

    var isVisible: Bool { panel.isVisible }

    func setVisible(_ visible: Bool) {
        guard visible != panel.isVisible else { return }
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
}

struct OverlayView: View {
    @ObservedObject var monitor: LiveMonitor
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let live = monitor.live {
                details(live)
            } else {
                Text("Camera idle").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(monitor.live == nil ? Color.gray : Color.green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(appName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if monitor.live?.appsAreGuess == true {
                    Text("probably — no app is using the microphone").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let live = monitor.live {
                // Updates every second along with the stream details.
                Text(elapsed(since: live.startedAt)).monospacedDigit().foregroundStyle(.secondary)
            }
            Button { model.dismissOverlay() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide until the camera is next used")
        }
    }

    private var appName: String {
        guard let live = monitor.live else { return "LogiCam Tuner" }
        if let names = live.appNames { return names }
        return model.cameraInUse ? "Unknown app" : "LogiCam Tuner preview"
    }

    private func details(_ live: LiveStream) -> some View {
        let v = live.values
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("Camera", live.camera.name)
            row("Video", "\(live.resolution) · \(fps(live.configuredFrameRate)) fps")
            row("Measured", measured(live))
            row("Format", live.pixelFormat)
            if let previous = live.upgradedFrom {
                GridRow {
                    Text("Fixed").foregroundStyle(.secondary)
                    Text("was \(previous)").foregroundStyle(.green).lineLimit(1)
                }
            }
            Divider().gridCellColumns(2)
            if live.camera.uvc == nil {
                reported(live.metadata)
            } else {
                controlled(v)
            }
            if model.smart.isEnabled, model.smartStatus != nil {
                Divider().gridCellColumns(2)
                GridRow { SmartStatusLabel().gridCellColumns(2) }
            }
        }
    }

    /// What a camera without controls, such as the Mac's built-in one, says its automatics chose.
    @ViewBuilder private func reported(_ m: FrameMetadata?) -> some View {
        row("Exposure", ["Auto", m?.exposureTime.map(ShutterSpeed.label(seconds:)), m?.iso.map { String(format: "ISO %.0f", $0) }]
            .compactMap { $0 }.joined(separator: " · "))
        row("Colour", ["Auto", m?.colorTemperature.map { "\($0) K" }].compactMap { $0 }.joined(separator: " · "))
        if let lux = m?.lux { row("Light", "\(lux) lux") }
    }

    /// The UVC camera's current control values.
    @ViewBuilder private func controlled(_ v: [String: Int]) -> some View {
        row("Exposure", [exposureMode(v), v["exposure_time"].map { ControlCatalog.format("exposure_time", $0) },
                         v["gain"].map { "ISO \($0)" }].compactMap { $0 }.joined(separator: " · "))
        row("Colour", [whiteBalanceMode(v), v["white_balance"].map { "\($0) K" }].compactMap { $0 }.joined(separator: " · "))
        row("Focus", focus(v))
        row("Image", [v["brightness"].map { "Brightness \($0)" }, v["zoom"].map { "Zoom " + ControlCatalog.format("zoom", $0) }]
            .compactMap { $0 }.joined(separator: " · "))
        row("Options", [v["backlight_compensation"].map { "HDR \($0 != 0 ? "on" : "off")" },
                        v["power_line_frequency"].map(flicker), v["exposure_priority"].map { "Low-light \($0 != 0 ? "on" : "off")" }]
            .compactMap { $0 }.joined(separator: " · "))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).monospacedDigit().lineLimit(1)
        }
    }

    /// What LogiCam Tuner's own connection receives, which matches what the camera delivers.
    private func measured(_ live: LiveStream) -> String {
        guard let rate = live.measuredFrameRate else { return "—" }
        // With auto-exposure priority, long shutter times lower the delivered frame rate.
        let limited = rate < live.configuredFrameRate * 0.9 ? "  (slowed by shutter)" : ""
        return "\(fps(rate)) fps\(limited)"
    }

    private func fps(_ value: Double) -> String { value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value) }

    private func exposureMode(_ v: [String: Int]) -> String? {
        if model.smart.exposure { return "Smart" }
        guard let mode = v["exposure_mode"] else { return nil }
        return mode & 0b0101 != 0 ? "Manual" : "Auto"
    }

    private func whiteBalanceMode(_ v: [String: Int]) -> String? {
        if model.smart.whiteBalance { return "Smart" }
        return v["white_balance_auto"].map { $0 != 0 ? "Auto" : "Manual" }
    }

    private func focus(_ v: [String: Int]) -> String {
        if v["focus_auto"] == 1 { return "Auto" }
        return v["focus"].map { "Manual · \($0)" } ?? "—"
    }

    private func flicker(_ value: Int) -> String {
        switch value {
        case 1: "50 Hz"
        case 2: "60 Hz"
        case 3: "Flicker auto"
        default: "Flicker off"
        }
    }

    private func elapsed(since start: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(start)), 0)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
