import AppKit
import CamDialKit
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
        .navigationTitle(model.selectedCamera?.name ?? "CamDial")
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            model.setPreview(false, owner: "window")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            model.setPreview(true, owner: "window")
        }
    }

    private var previewPane: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if model.selectedCamera == nil {
                Text("No USB video camera found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = model.previewSession {
                PreviewView(session: session, mirrored: mirrored)
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
        return parts.joined(separator: "  ·  ")
    }

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.selectedCamera != nil { ControlsPanel() }
                GroupBox("App") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Mirror preview", isOn: $mirrored)
                        Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        Text("Closing this window keeps CamDial in the menu bar, so Smart Auto keeps working.")
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
                Picker("Camera", selection: $model.selectedCameraID) {
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $mirrored) { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .help("Mirror the preview")
            Button { model.reload() } label: { Label("Re-read camera", systemImage: "arrow.clockwise") }
                .help("Re-read camera").disabled(model.selectedCamera == nil)
            Button { model.resetToDefaults() } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise.circle") }
                .help("Reset every control to the camera's default").disabled(model.selectedCamera == nil)
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
                Text(model.selectedCamera?.name ?? "CamDial").font(.headline)
                Spacer()
                Button {
                    openWindow(id: CamDialApp.mainWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Open CamDial", systemImage: "macwindow") }
                    .help("Open the main window with a large live preview")
            }
            if model.selectedCamera != nil {
                ScrollView { ControlsPanel() }.frame(maxHeight: 520)
            } else {
                Text("No USB video camera found.").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Button("Reset to defaults") { model.resetToDefaults() }.disabled(model.selectedCamera == nil)
                Spacer()
                Button("Quit CamDial") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 370)
    }
}
