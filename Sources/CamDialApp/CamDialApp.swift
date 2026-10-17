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
    @State private var showPreview = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let camera = model.selectedCamera {
                if showPreview {
                    PreviewView(camera: camera)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ControlSection.allCases) { section in
                            let rows = model.controls.filter { ControlSection.of($0.id) == section }
                                .compactMap { model.states[$0.id] }
                            if !rows.isEmpty {
                                GroupBox(section.rawValue) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(rows, id: \.control.id) { state in
                                            ControlRow(state: state) { model.set(state.control.id, $0) }
                                        }
                                    }
                                    .padding(4)
                                }
                            }
                        }
                        presets
                    }
                }
                .frame(maxHeight: 520)
            } else {
                Text("No USB video camera found.").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            footer
        }
        .padding(12)
        .frame(width: 360)
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
            Toggle(isOn: $showPreview) { Image(systemName: "eye") }
                .toggleStyle(.button).help("Live preview")
                .disabled(model.selectedCamera == nil)
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read camera").disabled(model.selectedCamera == nil)
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
            }
            .padding(4)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset to defaults") { model.resetToDefaults() }.disabled(model.selectedCamera == nil)
            Spacer()
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
