import AVFoundation
import CamDialKit
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

/// Diagnostics: `log stream --predicate 'subsystem == "io.github.camdial"'`.
private let log = Logger(subsystem: "io.github.camdial", category: "app")

/// Who decides exposure or white balance.
enum AutoMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case smart = "Smart"
    case manual = "Manual"
    var id: String { rawValue }
}

/// Owns the selected camera, its control snapshot, presets and Smart Auto. Hardware I/O runs on `io`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cameras: [CameraInfo] = []
    @Published var selectedCameraID: UInt64? { didSet { if oldValue != selectedCameraID { openSelected() } } }
    @Published private(set) var states: [String: ControlState] = [:]
    @Published private(set) var controls: [CameraControl] = []
    @Published private(set) var presetNames: [String] = []
    @Published private(set) var startupPreset: String?
    @Published var errorMessage: String?
    @Published private(set) var smart = SmartAutoSettings()
    @Published private(set) var smartStatus: SmartAutoStatus?
    /// Another app is streaming from the selected camera.
    @Published private(set) var cameraInUse = false
    @Published var previewVisible = false { didSet { updateFeed() } }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var camera: Camera?
    private var feed: CameraFeed?
    private var smartAuto: SmartAuto?
    private var monitor: CameraMonitor?
    private var usageTimer: Timer?
    private var cameraAccess: Bool?
    /// While Smart Auto streams, when to next pause and check for other apps.
    private var nextProbe = Date.distantPast
    private var probing = false
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
        // CoreMediaIO's "running somewhere" is polled: it is cheap, and there is no KVO for it.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollUsage() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handBackToCamera() }
        }
    }

    var selectedCamera: CameraInfo? { cameras.first { $0.id == selectedCameraID } }
    var previewSession: AVCaptureSession? { feed?.session }

    func refreshCameras() {
        let found = Camera.list()
        cameras = found
        initialized.formIntersection(found.map(\.id))
        if selectedCameraID == nil || !found.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = (found.first(where: \.isLogitech) ?? found.first)?.id
        }
        if selectedCameraID == nil { close() }
        for info in found where !initialized.contains(info.id) {
            initialized.insert(info.id)
            applyStartupPreset(info)
        }
    }

    private func close() {
        feed?.stop()
        feed = nil
        smartAuto = nil
        smartStatus = nil
        camera = nil
        controls = []
        states = [:]
    }

    private func openSelected() {
        close()
        guard let info = selectedCamera else { return }
        smart = store.smartAuto(for: info)
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
                    self.attachFeed(camera)
                case let .failure(error):
                    self.errorMessage = "\(error)"
                }
                self.reloadPresets()
            }
        }
    }

    // MARK: Feed and Smart Auto

    private func attachFeed(_ camera: Camera) {
        guard let feed = CameraFeed(camera.info) else { return }
        let smartAuto = SmartAuto(camera: camera, feed: feed, io: io)
        smartAuto.onStatus = { [weak self] status in self?.apply(status) }
        smartAuto.settings = smart
        self.feed = feed
        self.smartAuto = smartAuto
        cameraInUse = feed.isStreamingSomewhere
        nextProbe = Date() + 20
        updateFeed()
    }

    private func pollUsage() {
        guard let feed, !probing else { return }
        guard feed.isRunning else {
            setCameraInUse(feed.isStreamingSomewhere)
            return
        }
        // CamDial's own stream makes the camera look busy. When streaming only for Smart Auto,
        // pause now and then to see whether another app still is.
        guard !previewVisible, Date() >= nextProbe else { return }
        probing = true
        feed.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.feed === feed else { return }
            self.probing = false
            self.nextProbe = Date() + 20
            self.setCameraInUse(feed.isStreamingSomewhere)
            self.updateFeed()
        }
    }

    private func setCameraInUse(_ inUse: Bool) {
        guard inUse != cameraInUse else { return }
        log.notice("camera in use by another app: \(inUse)")
        cameraInUse = inUse
        if inUse { nextProbe = Date() + 20 }
        updateFeed()
    }

    /// Streams only while the preview is open or Smart Auto has a video app to serve, so CamDial
    /// never turns the camera light on by itself.
    private func updateFeed() {
        guard let feed else { return }
        let wanted = previewVisible || (smart.isEnabled && cameraInUse)
        guard wanted else {
            if feed.isRunning { log.notice("stopping capture") }
            feed.stop()
            return
        }
        withCameraAccess { granted in
            log.notice("starting capture: preview \(self.previewVisible), smart \(self.smart.isEnabled), access \(granted)")
            if granted { feed.start() } else { self.errorMessage = "Allow camera access in System Settings → Privacy & Security → Camera." }
        }
    }

    private func withCameraAccess(_ body: @escaping @MainActor (Bool) -> Void) {
        if let cameraAccess { body(cameraAccess); return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraAccess = granted
                body(granted)
            }
        }
    }

    private func apply(_ status: SmartAutoStatus) {
        if status.problem != smartStatus?.problem, let problem = status.problem { log.error("smart auto: \(problem)") }
        if status.needsMoreLight != smartStatus?.needsMoreLight { log.notice("smart auto needs more light: \(status.needsMoreLight)") }
        smartStatus = status
        // Show Smart Auto's values live without re-reading the camera.
        if let e = status.exposure {
            if let s = states["exposure_time"], s.current != e.time { states["exposure_time"] = s.with(current: e.time) }
            if let s = states["gain"], s.current != e.gain { states["gain"] = s.with(current: e.gain) }
        }
        if let k = status.whiteBalance, let s = states["white_balance"], s.current != k {
            states["white_balance"] = s.with(current: k)
        }
    }

    func updateSmart(_ change: (inout SmartAutoSettings) -> Void) {
        var next = smart
        change(&next)
        guard next != smart else { return }
        let ownershipChanged = next.ownedControls != smart.ownedControls
        smart = next
        smartAuto?.settings = next
        if let info = selectedCamera {
            do { try store.setSmartAuto(next, for: info) } catch { errorMessage = "\(error)" }
        }
        updateFeed()
        // Queued behind Smart Auto's own mode writes on `io`, so this shows the camera's new state.
        if ownershipChanged { reload() }
    }

    /// When CamDial quits, return Smart Auto's features to the camera's own automatics so the
    /// camera is not left on frozen manual values. Smart Auto resumes on the next launch.
    private func handBackToCamera() {
        guard let camera, smart.isEnabled else { return }
        let smart = self.smart
        io.sync {
            if smart.exposure, let auto = Self.cameraAutoExposure(camera) { try? camera.write("exposure_mode", value: auto) }
            if smart.whiteBalance { try? camera.write("white_balance_auto", value: 1) }
        }
    }

    // MARK: Modes

    var exposureModes: [AutoMode] {
        guard let mode = states["exposure_mode"] else { return [] }
        let values = Set(mode.choices.map(\.value))
        var modes: [AutoMode] = []
        if values.contains(2) || values.contains(8) { modes.append(.camera) }
        if values.contains(1), states["exposure_time"] != nil { modes += [.smart, .manual] }
        return modes
    }

    var exposureMode: AutoMode {
        if smart.exposure { return .smart }
        guard let mode = states["exposure_mode"]?.current else { return .camera }
        return mode & 0b0101 != 0 ? .manual : .camera
    }

    var whiteBalanceModes: [AutoMode] {
        guard states["white_balance_auto"] != nil, states["white_balance"] != nil else { return [] }
        return [.camera, .smart, .manual]
    }

    var whiteBalanceMode: AutoMode {
        if smart.whiteBalance { return .smart }
        return states["white_balance_auto"]?.current == 1 ? .camera : .manual
    }

    private nonisolated static func cameraAutoExposure(_ camera: Camera) -> Int? {
        guard let choices = try? camera.read("exposure_mode").choices.map(\.value) else { return nil }
        return [2, 8].first(where: choices.contains)
    }

    func setExposureMode(_ mode: AutoMode) {
        guard let camera, mode != exposureMode else { return }
        updateSmart { $0.exposure = mode == .smart }
        guard mode != .smart else { return }
        io.async { [weak self] in
            if mode == .camera {
                if let auto = Self.cameraAutoExposure(camera) { try? camera.write("exposure_mode", value: auto) }
            } else {
                // Freeze whatever the camera or Smart Auto chose, so switching to manual changes nothing visible.
                let time = try? camera.read("exposure_time").current
                let gain = try? camera.read("gain").current
                try? camera.write("exposure_mode", value: 1)
                if let time { try? camera.write("exposure_time", value: time) }
                if let gain { try? camera.write("gain", value: gain) }
            }
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func setWhiteBalanceMode(_ mode: AutoMode) {
        guard let camera, mode != whiteBalanceMode else { return }
        updateSmart { $0.whiteBalance = mode == .smart }
        guard mode != .smart else { return }
        io.async { [weak self] in
            if mode == .camera {
                try? camera.write("white_balance_auto", value: 1)
            } else {
                let kelvin = try? camera.read("white_balance").current
                try? camera.write("white_balance_auto", value: 0)
                if let kelvin { try? camera.write("white_balance", value: kelvin) }
            }
            DispatchQueue.main.async { self?.reload() }
        }
    }

    // MARK: Controls

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

    /// Whether the user can edit a control right now: Smart Auto owns some controls while enabled.
    func isEditable(_ state: ControlState) -> Bool {
        state.isWritable && !smart.ownedControls.contains(state.control.id)
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
                // Anti-flicker affects Smart Auto's shutter choices.
                if batch["power_line_frequency"] != nil { self.smartAuto?.refreshCameraState() }
            }
        }
    }

    func resetToDefaults() {
        guard let camera else { return }
        let owned = smart.ownedControls
        io.async { [weak self] in
            for state in camera.readAll() where state.info.contains(.set) && !owned.contains(state.control.id) {
                if let def = state.defaultValue, def != state.current { try? camera.write(state.control, value: def) }
            }
            // A second pass catches values that were locked until their mode reset.
            for state in camera.readAll() where state.isWritable && !owned.contains(state.control.id) {
                if let def = state.defaultValue, def != state.current { try? camera.write(state.control, value: def) }
            }
            DispatchQueue.main.async {
                self?.reload()
                self?.smartAuto?.refreshCameraState()
            }
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
        let owned = smart.ownedControls
        io.async { [weak self] in
            let failures = preset.apply(to: camera, skipping: owned)
            DispatchQueue.main.async {
                self?.errorMessage = failures.first.map { "\($0.control): \($0.error)" }
                self?.reload()
                self?.smartAuto?.refreshCameraState()
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
        let owned = store.smartAuto(for: info).ownedControls
        io.async { [weak self] in
            guard let camera = try? Camera(info) else { return }
            _ = preset.apply(to: camera, skipping: owned)
            DispatchQueue.main.async { if self?.selectedCameraID == info.id { self?.reload() } }
        }
    }

    // MARK: App

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
