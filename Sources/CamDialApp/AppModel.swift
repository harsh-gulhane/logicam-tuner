import CamDialKit
import Foundation
import SwiftUI

/// Owns the selected camera, its control snapshot and presets. Hardware I/O runs on `io`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cameras: [CameraInfo] = []
    @Published var selectedCameraID: UInt64? { didSet { if oldValue != selectedCameraID { openSelected() } } }
    @Published private(set) var states: [String: ControlState] = [:]
    @Published private(set) var controls: [CameraControl] = []
    @Published private(set) var presetNames: [String] = []
    @Published private(set) var startupPreset: String?
    @Published var errorMessage: String?

    private var camera: Camera?
    private var monitor: CameraMonitor?
    private let store = PresetStore()
    private let io = DispatchQueue(label: "camdial.io")
    /// Latest requested value per control; slider drags coalesce into one write per I/O turn.
    private var pendingWrites: [String: Int] = [:]
    private var writeScheduled = false
    /// Cameras we have already applied a startup preset to during this attachment.
    private var initialized: Set<UInt64> = []

    init() {
        monitor = CameraMonitor { [weak self] _ in self?.refreshCameras() }
        refreshCameras()
    }

    var selectedCamera: CameraInfo? { cameras.first { $0.id == selectedCameraID } }

    func refreshCameras() {
        let found = Camera.list()
        cameras = found
        initialized.formIntersection(found.map(\.id))
        if selectedCameraID == nil || !found.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = (found.first(where: \.isLogitech) ?? found.first)?.id
        }
        if selectedCameraID == nil {
            camera = nil
            controls = []
            states = [:]
        }
        for info in found where !initialized.contains(info.id) {
            initialized.insert(info.id)
            applyStartupPreset(info)
        }
    }

    private func openSelected() {
        guard let info = selectedCamera else { return }
        io.async { [weak self] in
            let result = Result { try Camera(info) }
            let snapshot = (try? result.get())?.readAll() ?? []
            DispatchQueue.main.async {
                guard let self, self.selectedCameraID == info.id else { return }
                switch result {
                case let .success(camera):
                    self.camera = camera
                    self.controls = camera.controls
                    self.states = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.control.id, $0) })
                    self.errorMessage = nil
                case let .failure(error):
                    self.camera = nil
                    self.controls = []
                    self.states = [:]
                    self.errorMessage = "\(error)"
                }
                self.reloadPresets()
            }
        }
    }

    /// Re-reads every control, e.g. after a mode change unlocks others.
    func reload() {
        guard let camera else { return }
        io.async { [weak self] in
            let snapshot = camera.readAll()
            DispatchQueue.main.async {
                guard let self, self.camera === camera else { return }
                self.states = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.control.id, $0) })
            }
        }
    }

    func set(_ id: String, _ value: Int) {
        guard let camera else { return }
        pendingWrites[id] = value
        guard !writeScheduled else { return }
        writeScheduled = true
        io.async { [weak self] in
            let batch: [String: Int] = DispatchQueue.main.sync {
                guard let self else { return [:] }
                defer { self.pendingWrites = [:]; self.writeScheduled = false }
                return self.pendingWrites
            }
            var errors: [String] = []
            for definition in ControlCatalog.all {
                guard let value = batch[definition.id] else { continue }
                do { try camera.write(definition.id, value: value) } catch { errors.append("\(error)") }
            }
            // Mode controls change which other controls are writable, so refresh everything.
            let snapshot = camera.readAll()
            DispatchQueue.main.async {
                guard let self, self.camera === camera else { return }
                self.states = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.control.id, $0) })
                self.errorMessage = errors.first
            }
        }
    }

    func resetToDefaults() {
        guard let camera else { return }
        io.async { [weak self] in
            for state in camera.readAll() where state.info.contains(.set) {
                if let def = state.defaultValue, def != state.current { try? camera.write(state.control, value: def) }
            }
            // A second pass catches values that were locked until their mode reset.
            for state in camera.readAll() where state.isWritable {
                if let def = state.defaultValue, def != state.current { try? camera.write(state.control, value: def) }
            }
            DispatchQueue.main.async { self?.reload() }
        }
    }

    // MARK: Presets

    private func reloadPresets() {
        guard let info = selectedCamera else { presetNames = []; startupPreset = nil; return }
        presetNames = store.presets(for: info).keys.sorted()
        startupPreset = store.startupPreset(for: info)
    }

    func savePreset(named name: String) {
        guard let camera, !name.isEmpty else { return }
        io.async { [weak self] in
            let preset = Preset.capture(camera)
            DispatchQueue.main.async {
                guard let self else { return }
                do { try self.store.save(preset, named: name, for: camera.info) } catch { self.errorMessage = "\(error)" }
                self.reloadPresets()
            }
        }
    }

    func applyPreset(named name: String) {
        guard let camera, let preset = store.presets(for: camera.info)[name] else { return }
        io.async { [weak self] in
            let failures = preset.apply(to: camera)
            DispatchQueue.main.async {
                self?.errorMessage = failures.first.map { "\($0.control): \($0.error)" }
                self?.reload()
            }
        }
    }

    func deletePreset(named name: String) {
        guard let info = selectedCamera else { return }
        do { try store.delete(named: name, for: info) } catch { errorMessage = "\(error)" }
        reloadPresets()
    }

    func setStartupPreset(_ name: String?) {
        guard let info = selectedCamera else { return }
        do { try store.setStartupPreset(name, for: info) } catch { errorMessage = "\(error)" }
        reloadPresets()
    }

    private func applyStartupPreset(_ info: CameraInfo) {
        guard let name = store.startupPreset(for: info), let preset = store.presets(for: info)[name] else { return }
        io.async { [weak self] in
            guard let camera = try? Camera(info) else { return }
            _ = preset.apply(to: camera)
            DispatchQueue.main.async { if self?.selectedCameraID == info.id { self?.reload() } }
        }
    }
}
