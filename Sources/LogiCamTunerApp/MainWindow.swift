import AppKit
import LogiCamKit
import SwiftUI

/// The main window: a large live preview beside every control, so changes are visible as they are made.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("mirrorPreview") private var mirrored = true

    var body: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            controlsPane
                .frame(minWidth: 340, idealWidth: 390, maxWidth: 520)
        }
        .frame(minWidth: 880, minHeight: 560)
        .navigationTitle("LogiCam Tuner")
        .navigationSubtitle(model.selectedCamera?.name ?? "No camera")
        .toolbar { toolbar }
        .onAppear { model.setPreview(true, owner: "window") }
        .onDisappear { model.setPreview(false, owner: "window") }
        // Stop streaming while the window is out of sight, so the camera light goes off.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            model.setPreview(false, owner: "window")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            model.setPreview(true, owner: "window")
        }
        // Pause while another app is in front: the call app shows its own picture, and LogiCam Tuner
        // can only tell which other apps use the camera while it is not streaming itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.setPreview(false, owner: "window")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.setPreview(true, owner: "window")
        }
    }

    private var previewPane: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if model.selectedCamera == nil {
                Text("No camera found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let feed = model.previewFeed {
                PreviewView(feed: feed, mirrored: mirrored)
                if !model.previewVisible {
                    Label("Preview paused while LogiCam Tuner is in the background", systemImage: "pause.circle")
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.white).lineLimit(3)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                }
                if !readout.isEmpty {
                    Text(readout).font(.callout.monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .padding(12)
        }
    }

    /// Current exposure and colour, so their effect on the picture can be read at a glance.
    private var readout: String {
        var parts: [String] = []
        if let s = model.states["exposure_time"] { parts.append(ControlCatalog.format(s.control.id, s.current)) }
        if let s = model.states["gain"] { parts.append("ISO \(s.current)") }
        if let s = model.states["white_balance"] { parts.append(ControlCatalog.format(s.control.id, s.current)) }
        if model.smart.isEnabled { parts.append("Smart") }
        if let stream = model.streamInfo { parts.append(stream) }
        return parts.joined(separator: "  ·  ")
    }

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.selectedCamera?.uvc != nil { ControlsPanel() } else if model.selectedCamera != nil { NoControlsNote() }
                SessionsView(monitor: model.liveMonitor)
                GroupBox("App") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Mirror preview", isOn: $mirrored)
                        Picker("Preview frame rate", selection: $model.frameRate) {
                            Text("30 fps").tag(30.0)
                            Text("60 fps").tag(60.0)
                        }
                        Text("Video apps choose their own resolution and frame rate. While one is using the camera, the preview shows that stream unchanged. Shutter speeds longer than one frame (1/60 s at 60 fps) lower the frame rate when Low-light boost is on.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Toggle("Fix slow video modes", isOn: $model.fixSlowModes)
                            .help("Some apps, such as WhatsApp, pick the camera's largest mode, which runs at only 5 fps. Switch them to 1080p at 30 fps.")
                        Picker("Stream overlay", selection: $model.overlayMode) {
                            ForEach(OverlayMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        Text("Closing this window keeps LogiCam Tuner in the menu bar, so Smart Auto keeps working.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build") · unofficial community app, not affiliated with Logitech.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.cameras.count > 1 {
                Picker("Camera", selection: Binding(get: { model.selectedCameraID }, set: { $0.map(model.chooseCamera) })) {
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                .help("While LogiCam Tuner is in the background, the overlay follows whichever camera an app is using")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $mirrored) { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .help("Mirror the preview")
            Button { model.reload() } label: { Label("Re-read camera", systemImage: "arrow.clockwise") }
                .help("Re-read camera").disabled(model.selectedCamera?.uvc == nil)
            Button { model.resetToDefaults() } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise.circle") }
                .help("Reset every control to the camera's default").disabled(model.selectedCamera?.uvc == nil)
        }
    }
}

/// The compact panel behind the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LogiCam Tuner").font(.headline)
                    if let camera = model.selectedCamera { Text(camera.name).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button {
                    openWindow(id: LogiCamTunerApp.mainWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Open LogiCam Tuner", systemImage: "macwindow") }
                    .help("Open the main window with a large live preview")
            }
            MenuStreamSection(monitor: model.liveMonitor)
            if model.selectedCamera?.uvc != nil {
                ScrollView { ControlsPanel() }.frame(maxHeight: 520)
            } else if model.selectedCamera != nil {
                NoControlsNote()
            } else {
                Text("No camera found.").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Picker("Overlay", selection: $model.overlayMode) {
                ForEach(OverlayMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .font(.caption)
            HStack {
                Button("Reset to defaults") { model.resetToDefaults() }.disabled(model.selectedCamera?.uvc == nil)
                Spacer()
                Button("Quit LogiCam Tuner") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 370)
    }
}

/// In place of the controls, for cameras such as the Mac's built-in one that only macOS adjusts.
struct NoControlsNote: View {
    var body: some View {
        GroupBox("Camera") {
            Text("macOS sets this camera's exposure, white balance and focus itself; it has no manual controls or Smart Auto. The overlay and the readout on the preview show what it chose. Portrait, Studio Light and Center Stage are under Video Effects in Control Centre while an app uses the camera.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The live stream's stats in the menu-bar panel, for a quick look without the overlay. The
/// details fold away; the one-line summary stays.
struct MenuStreamSection: View {
    @ObservedObject var monitor: LiveMonitor
    @EnvironmentObject private var model: AppModel
    @AppStorage("menuStatsExpanded") private var expanded = true

    var body: some View {
        GroupBox {
            if let live = monitor.live {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        StreamStatsView(live: live).font(.caption)
                        if model.cameraInUse, !model.isOverlayVisible {
                            Button("Show overlay") { model.showOverlay() }.buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(StreamText.appName(live, cameraInUse: model.cameraInUse)).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(StreamText.summary(live)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Camera idle", systemImage: "video.slash").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
