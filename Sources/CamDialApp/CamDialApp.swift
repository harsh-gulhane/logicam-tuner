import CamDialKit
import SwiftUI

@main
struct CamDialApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("CamDial", systemImage: "web.camera") {
            ContentView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.selectedCamera != nil {
                if model.previewVisible, let session = model.previewSession {
                    PreviewView(session: session)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if model.smart.isEnabled { smartStatus }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ControlSection.allCases) { section in
                            sectionView(section)
                        }
                        presets
                    }
                }
                .frame(maxHeight: 560)
            } else {
                Text("No USB video camera found.").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            footer
        }
        .padding(12)
        .frame(width: 370)
    }

    private var header: some View {
        HStack {
            if model.cameras.count > 1 {
                Picker("Camera", selection: $model.selectedCameraID) {
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            } else {
                Text(model.selectedCamera?.name ?? "CamDial").font(.headline)
            }
            Spacer()
            Toggle(isOn: $model.previewVisible) { Image(systemName: "eye") }
                .toggleStyle(.button).help("Live preview")
                .disabled(model.selectedCamera == nil)
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read camera").disabled(model.selectedCamera == nil)
        }
    }

    // MARK: Smart Auto

    private var smartStatus: some View {
        let (icon, text, color): (String, String, Color) = {
            guard let status = model.smartStatus, model.cameraInUse || model.previewVisible else {
                return ("pause.circle", "Smart Auto starts when an app uses the camera.", .secondary)
            }
            if let problem = status.problem { return ("exclamationmark.triangle", problem, .orange) }
            if status.needsMoreLight {
                return ("moon", "Too dark for the current limits: allow a lower frame rate, raise Max ISO or add light.", .orange)
            }
            let face = status.faceDetected ? " · face detected" : ""
            return status.adjusting ? ("wand.and.rays", "Smart Auto adjusting\(face)", .secondary)
                : ("checkmark.circle", "Smart Auto steady\(face)", .secondary)
        }()
        return Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
    }

    @ViewBuilder private func modePicker(_ modes: [AutoMode], _ selection: AutoMode, _ set: @escaping (AutoMode) -> Void) -> some View {
        if modes.count > 1 {
            Picker("Mode", selection: Binding(get: { selection }, set: set)) {
                ForEach(modes) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var exposureSmartOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreferenceSlider(title: "Exposure compensation", value: model.smart.exposureBias, range: -2...2, step: 0.1,
                             format: { String(format: "%+.1f EV", $0) }) { v in model.updateSmart { $0.exposureBias = v } }
            Toggle("Expose for faces", isOn: Binding(get: { model.smart.facePriority },
                                                     set: { v in model.updateSmart { $0.facePriority = v } }))
                .help("Meters detected faces first, so a window behind you does not leave your face dark.")
            Picker("In low light", selection: Binding(get: { model.smart.minimumFrameRate },
                                                      set: { v in model.updateSmart { $0.minimumFrameRate = v } })) {
                Text("Keep frame rate").tag(30.0)
                Text("Down to 15 fps").tag(15.0)
                Text("Down to 7.5 fps").tag(7.5)
            }
            PreferenceSlider(title: "Max ISO", value: model.smart.maxGain, range: 0.25...1, step: 0.05,
                             format: { String(format: "%.0f%%", $0 * 100) }) { v in model.updateSmart { $0.maxGain = v } }
        }
    }

    private var whiteBalanceSmartOptions: some View {
        PreferenceSlider(title: "Warmth", value: model.smart.warmth, range: -1...1, step: 0.1, format: { v in
            abs(v) < 0.05 ? "Neutral" : String(format: v > 0 ? "Warmer %.1f" : "Cooler %.1f", abs(v))
        }) { v in model.updateSmart { $0.warmth = v } }
    }

    // MARK: Sections

    @ViewBuilder private func sectionView(_ section: ControlSection) -> some View {
        let rows = model.controls.filter { ControlSection.of($0.id) == section }
            .filter { !(model.smart.exposure && $0.id == "exposure_priority") } // Smart Auto manages it
            .compactMap { model.states[$0.id] }
        let exposureModes = section == .exposure ? model.exposureModes : []
        let wbModes = section == .whiteBalance ? model.whiteBalanceModes : []
        if !rows.isEmpty || !exposureModes.isEmpty || !wbModes.isEmpty {
            GroupBox(section.rawValue) {
                VStack(alignment: .leading, spacing: 8) {
                    if section == .exposure {
                        modePicker(exposureModes, model.exposureMode, model.setExposureMode)
                        if model.exposureMode == .smart { exposureSmartOptions; Divider() }
                    }
                    if section == .whiteBalance {
                        modePicker(wbModes, model.whiteBalanceMode, model.setWhiteBalanceMode)
                        if model.whiteBalanceMode == .smart { whiteBalanceSmartOptions }
                    }
                    ForEach(rows, id: \.control.id) { state in
                        ControlRow(state: state, editable: model.isEditable(state),
                                   ownerLabel: model.smart.ownedControls.contains(state.control.id) ? "Smart" : nil) {
                            model.set(state.control.id, $0)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private var presets: some View {
        GroupBox("Presets") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.presetNames, id: \.self) { name in
                    HStack {
                        Button(name) { model.applyPreset(named: name) }.buttonStyle(.link)
                        Spacer()
                        Button {
                            model.setStartupPreset(model.startupPreset == name ? nil : name)
                        } label: {
                            Image(systemName: model.startupPreset == name ? "bolt.fill" : "bolt")
                        }
                        .buttonStyle(.borderless)
                        .help("Apply automatically when this camera connects")
                        Button(role: .destructive) { model.deletePreset(named: name) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Save current settings as…", text: $newPresetName)
                        .onSubmit(save)
                    Button("Save", action: save).disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if model.smart.isEnabled {
                    Text("Presets leave settings that Smart Auto controls unchanged.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset to defaults") { model.resetToDefaults() }.disabled(model.selectedCamera == nil)
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                .toggleStyle(.checkbox).font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func save() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.savePreset(named: name)
        newPresetName = ""
    }
}
