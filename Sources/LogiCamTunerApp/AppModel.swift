import AVFoundation
import LogiCamKit
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

/// Diagnostics go to the unified log (`log stream --predicate 'subsystem == "io.github.logicamtuner"'`)
/// and to ~/Library/Logs/LogiCamTuner.log, which users can attach to bug reports without admin rights.
enum Diagnostics {
    static let logger = Logger(subsystem: "io.github.logicamtuner", category: "app")
    static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/LogiCamTuner.log")
    private static let queue = DispatchQueue(label: "logicam.log")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            // Start over past 1 MB so the file cannot grow without bound.
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: file)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}

/// Who decides exposure or white balance.
enum AutoMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case smart = "Smart"
    case manual = "Manual"
    var id: String { rawValue }
}

/// Owns the selected camera, its control snapshot, presets and Smart Auto. Hardware I/O runs on `io`.
///
/// Any camera can be selected; only UVC cameras have controls, presets and Smart Auto. While the
/// window is not showing the preview, the selection follows the camera another app is using, so the
/// overlay describes that stream, and returns to the chosen camera when no app is using one.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cameras: [VideoCamera] = []
    @Published private(set) var selectedCameraID: String? { didSet { if oldValue != selectedCameraID { openSelected() } } }
    @Published private(set) var states: [String: ControlState] = [:]
    @Published private(set) var controls: [CameraControl] = []
    @Published private(set) var presetNames: [String] = []
    @Published private(set) var startupPreset: String?
    /// Shown in the window for a few seconds.
    @Published var errorMessage: String? {
        didSet {
            guard let message = errorMessage else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if self?.errorMessage == message { self?.errorMessage = nil }
            }
        }
    }
    @Published private(set) var smart = SmartAutoSettings()
    @Published private(set) var smartStatus: SmartAutoStatus?
    /// Another app is streaming from the selected camera.
    @Published private(set) var cameraInUse = false
    /// Views currently showing the live preview (the main window, the menu-bar panel).
    @Published private(set) var previewOwners: Set<String> = []
    var previewVisible: Bool { !previewOwners.isEmpty }
    /// Frame rate LogiCam Tuner asks for while it is the only app using the camera.
    @Published var frameRate = UserDefaults.standard.object(forKey: "frameRate") as? Double ?? 60 {
        didSet {
            UserDefaults.standard.set(frameRate, forKey: "frameRate")
            feed?.preferredFrameRate = frameRate
            feed?.restart()
        }
    }
    /// Resolution and measured frame rate of the stream, while LogiCam Tuner is receiving it.
    @Published private(set) var streamInfo: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var overlayMode = OverlayMode(rawValue: UserDefaults.standard.string(forKey: "overlayMode") ?? "")
        ?? .whileInUse {
        didSet {
            UserDefaults.standard.set(overlayMode.rawValue, forKey: "overlayMode")
            overlayDismissed = false
            updateOverlay()
            updateFeed()
        }
    }
    /// While another app uses the camera, stream from it too, to measure the frame rate it really delivers
    /// and read the exposure that cameras without controls report. Off by default: macOS lists every app
    /// streaming from the camera in its camera menu, next to the call app.
    @Published var measureStream = UserDefaults.standard.bool(forKey: "measureStream") {
        didSet {
            UserDefaults.standard.set(measureStream, forKey: "measureStream")
            updateFeed()
        }
    }
    /// Switch apps that pick a very slow camera mode (WhatsApp picks the StreamCam's 5 fps one) to 1080p30.
    @Published var fixSlowModes = UserDefaults.standard.object(forKey: "fixSlowModes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fixSlowModes, forKey: "fixSlowModes") }
    }
    /// Switches attempted during the current camera session; capped so an app that insists on its
    /// own mode is not fought over.
    private var formatUpgrades = 0
    let liveMonitor = LiveMonitor()
    private var overlay: OverlayController?
    /// The overlay was closed for the current camera session.
    private var overlayDismissed = false

    private var camera: Camera?
    private var feed: CameraFeed?
    private var smartAuto: SmartAuto?
    private var monitor: CameraMonitor?
    private var usageTimer: Timer?
    private var accessRequested = false
    /// While Smart Auto streams, when to next pause and check for other apps.
    private var nextProbe = Date.distantPast
    private var probing = false
    private let store = PresetStore()
    private let io = DispatchQueue(label: "logicam.io")
    /// Latest requested value per control; slider drags coalesce into one write per I/O turn.
    private var pendingWrites: [String: Int] = [:]
    private var writeScheduled = false
    /// Cameras we have already applied a startup preset to during this attachment.
    private var initialized: Set<UInt64> = []
    /// The camera picked in the window, kept across launches; nil means the first Logitech camera.
    private var chosenCameraID = UserDefaults.standard.string(forKey: "camera")
    /// When the selection last changed; following waits for the old camera to be released.
    private var selectedAt = Date.distantPast

    init() {
        monitor = CameraMonitor { [weak self] _ in self?.refreshCameras() }
        // Cameras that are not USB devices, such as Continuity Camera iPhones, come and go too.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCameras() }
            }
        }
        refreshCameras()
        // CoreMediaIO's "running somewhere" is polled: it is cheap, and there is no KVO for it.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollUsage() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handBackToCamera() }
        }
    }

    var selectedCamera: VideoCamera? { cameras.first { $0.id == selectedCameraID } }
    /// The selected camera's USB identity, when it is a UVC camera with controls.
    private var selectedUVC: CameraInfo? { selectedCamera?.uvc }

    /// Selects a camera from the window and remembers it as the one to return to.
    func chooseCamera(_ id: String) {
        chosenCameraID = id
        UserDefaults.standard.set(id, forKey: "camera")
        select(id)
    }

    private func select(_ id: String?) {
        guard id != selectedCameraID else { return }
        selectedAt = Date()
        selectedCameraID = id
    }

    private func chosenCamera(in cameras: [VideoCamera]) -> VideoCamera? {
        cameras.first { $0.id == chosenCameraID } ?? cameras.first { $0.uvc?.isLogitech == true }
            ?? cameras.first { $0.uvc != nil } ?? cameras.first
    }

    func setPreview(_ visible: Bool, owner: String) {
        guard visible != previewOwners.contains(owner) else { return }
        if visible { previewOwners.insert(owner) } else { previewOwners.remove(owner) }
        updateFeed()
    }
    /// The selected camera's feed, for previews.
    var previewFeed: CameraFeed? { feed }

    func refreshCameras() {
        let found = VideoCamera.list()
        let previous = selectedCamera
        cameras = found
        let usb = found.compactMap(\.uvc)
        initialized.formIntersection(usb.map(\.id))
        if let current = selectedCamera {
            // Replugged: same camera, new USB identity.
            if current != previous { openSelected() }
        } else {
            select(chosenCamera(in: found)?.id)
        }
        if selectedCameraID == nil { close() }
        for info in usb where !initialized.contains(info.id) {
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
        guard let selected = selectedCamera else { return }
        smart = selected.uvc.map(store.smartAuto) ?? SmartAutoSettings()
        guard let info = selected.uvc else {
            attachFeed(selected, camera: nil)
            reloadPresets()
            return
        }
        io.async { [weak self] in
            let result = Result { try Camera(info) }
            let snapshot = (try? result.get())?.readAll() ?? []
            DispatchQueue.main.async {
                guard let self, self.selectedCamera == selected else { return }
                switch result {
                case let .success(camera):
                    self.camera = camera
                    self.controls = camera.controls
                    self.states = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.control.id, $0) })
                    self.errorMessage = nil
                    self.attachFeed(selected, camera: camera)
                case let .failure(error):
                    self.errorMessage = "\(error)"
                    self.attachFeed(selected, camera: nil)
                }
                self.reloadPresets()
            }
        }
    }

    // MARK: Feed and Smart Auto

    /// Starts watching `selected`; `camera` is its UVC control connection, when it has one.
    private func attachFeed(_ selected: VideoCamera, camera: Camera?) {
        guard let feed = CameraFeed(selected) else { return }
        feed.preferredFrameRate = frameRate
        feed.onLog = { message in Diagnostics.note(message) }
        if let camera {
            let smartAuto = SmartAuto(camera: camera, feed: feed, io: io)
            smartAuto.onStatus = { [weak self] status in self?.apply(status) }
            smartAuto.settings = smart
            self.smartAuto = smartAuto
        }
        self.feed = feed
        cameraInUse = feed.isStreamingSomewhere
        nextProbe = Date() + Self.probeInterval
        updateFeed()
    }

    private func pollUsage() {
        feed?.restartIfStalled()
        updateStreamInfo()
        liveMonitor.update(feed: feed, camera: camera, active: cameraInUse || previewVisible, otherApp: cameraInUse, io: io)
        fixSlowModeIfNeeded()
        updateOverlay()
        followCameraInUse()
        guard let feed, !probing else { return }
        guard feed.isRunning else {
            // For a second or so after stopping, the camera still counts as running in this process;
            // reading "running somewhere" then would mistake LogiCam Tuner's own stream for another app.
            guard !feed.isStreamingInThisProcess else { return }
            setCameraInUse(feed.isStreamingSomewhere)
            return
        }
        // LogiCam Tuner's own stream makes the camera look busy. When streaming only for Smart Auto
        // or the overlay, pause now and then to see whether another app still is.
        guard !previewVisible, Date() >= nextProbe else { return }
        probing = true
        feed.stop()
        finishProbe(feed, deadline: Date() + 5)
    }

    /// Waits until the camera is released in this process, then checks for other apps. If it is not
    /// released in time, assume no other app: the camera stays off, and a call that is really still
    /// running is picked up by the next poll.
    private func finishProbe(_ feed: CameraFeed, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.feed === feed else { return }
            let released = !feed.isStreamingInThisProcess
            guard released || Date() >= deadline else { return self.finishProbe(feed, deadline: deadline) }
            let elsewhere = released && feed.isStreamingSomewhere
            // A probe that finds the call still running is routine; logging each one buried the rest of the log.
            if !elsewhere { Diagnostics.note("probe: released \(released), another app streaming false") }
            self.probing = false
            self.nextProbe = Date() + Self.probeInterval
            self.setCameraInUse(elsewhere)
            self.updateFeed(logging: false)
        }
    }

    /// While the preview is hidden, selects the camera another app is using, so the overlay and Smart
    /// Auto work on that stream, and goes back to the chosen camera once no app is using one.
    private func followCameraInUse() {
        // LogiCam Tuner's own stream lingers for a second or so after a switch.
        guard !previewVisible, !probing, Date().timeIntervalSince(selectedAt) > 3 else { return }
        let busy = cameras.filter { $0.id != selectedCameraID && $0.isStreamingSomewhere && !$0.isStreamingInThisProcess }
        guard let target = VideoCamera.follow(selected: selectedCamera, selectedInUse: cameraInUse, busy: busy,
                                              chosen: chosenCamera(in: cameras)) else { return }
        Diagnostics.note("following camera: \(target.name)" + (busy.contains(target) ? " (in use)" : " (back to chosen camera)"))
        select(target.id)
    }

    /// How often LogiCam Tuner pauses its own stream to check whether the call app is still there;
    /// also roughly how long the camera stays on after a call ends.
    static let probeInterval: TimeInterval = 10

    private func updateStreamInfo() {
        var info: String?
        if let feed, feed.isRunning {
            let d = feed.dimensions
            let fps = feed.measuredFrameRate
            info = fps > 0 ? String(format: "%d×%d · %.0f fps", d.width, d.height, fps) : "\(d.width)×\(d.height)"
            // Cameras without controls report their own exposure and colour with each frame.
            if camera == nil, let m = feed.metadata {
                let parts = [m.exposureTime.map(ShutterSpeed.label(seconds:)), m.iso.map { String(format: "ISO %.0f", $0) },
                             m.colorTemperature.map { "\($0) K" }].compactMap { $0 }
                info = (parts + [info].compactMap { $0 }).joined(separator: "  ·  ")
            }
        }
        if info != streamInfo { streamInfo = info }
    }

    private func setCameraInUse(_ inUse: Bool) {
        guard inUse != cameraInUse else { return }
        Diagnostics.note("camera in use by another app: \(inUse)")
        cameraInUse = inUse
        if inUse { nextProbe = Date() + Self.probeInterval } else { overlayDismissed = false; formatUpgrades = 0 }
        updateFeed()
        updateOverlay()
    }

    /// Streams only while the preview is open, or another app is streaming and Smart Auto needs frames or
    /// the stream is to be measured, so LogiCam Tuner never turns the camera light on by itself and
    /// otherwise stays out of macOS's camera menu during calls.
    private func updateFeed(logging: Bool = true) {
        guard let feed else { return }
        let wanted = previewVisible || ((smart.isEnabled || measureStream) && cameraInUse)
        guard wanted else {
            if logging, feed.isRunning { Diagnostics.note("stopping capture: preview \(previewVisible), in use \(cameraInUse)") }
            feed.stop()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if logging, !feed.isRunning { Diagnostics.note("starting capture: preview \(previewVisible), in use \(cameraInUse)") }
            feed.start()
        case .notDetermined:
            // The answer can take a while (macOS may show a prompt); decide again once it arrives,
            // since the reason to stream may have gone by then.
            guard !accessRequested else { return }
            accessRequested = true
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { self.accessRequested = false; self.updateFeed() }
            }
        default:
            errorMessage = "Allow camera access in System Settings → Privacy & Security → Camera."
        }
    }

    /// Below this, video looks like a slideshow; StreamCam's full-sensor mode runs at 5 fps.
    static let slowModeFrameRate = 15.0

    private func fixSlowModeIfNeeded() {
        guard fixSlowModes, cameraInUse, formatUpgrades < 2, let feed,
              feed.configuredFrameRate < Self.slowModeFrameRate else { return }
        formatUpgrades += 1
        let d = feed.dimensions
        let before = String(format: "%d×%d · %.0f fps", d.width, d.height, feed.configuredFrameRate)
        if let next = feed.upgradeSharedFormat(frameRate: 30) {
            Diagnostics.note("switched slow mode \(before) to \(next.width)×\(next.height) at 30 fps")
            liveMonitor.noteUpgrade(from: before)
        } else {
            Diagnostics.note("slow mode \(before): no better mode available")
        }
    }

    // MARK: Overlay

    func dismissOverlay() {
        overlayDismissed = true
        updateOverlay()
    }

    var isOverlayVisible: Bool { overlay?.isVisible == true }

    /// Brings the overlay back for the current stream, e.g. after it was closed during a call.
    func showOverlay() {
        overlayDismissed = false
        if overlayMode == .off { overlayMode = .whileInUse } else { updateOverlay() }
    }

    private func updateOverlay() {
        let show = overlayMode == .always || (overlayMode == .whileInUse && cameraInUse && !overlayDismissed)
        if show, overlay == nil { overlay = OverlayController(model: self, monitor: liveMonitor) }
        overlay?.setVisible(show)
    }

    private func apply(_ status: SmartAutoStatus) {
        if status.problem != smartStatus?.problem, let problem = status.problem { Diagnostics.note("smart auto: \(problem)") }
        if status.needsMoreLight != smartStatus?.needsMoreLight { Diagnostics.note("smart auto needs more light: \(status.needsMoreLight)") }
        // Publishing redraws every control, so only publish real changes.
        if status != smartStatus { smartStatus = status }
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
        if let info = selectedUVC {
            do { try store.setSmartAuto(next, for: info) } catch { errorMessage = "\(error)" }
        }
        updateFeed()
        // Queued behind Smart Auto's own mode writes on `io`, so this shows the camera's new state.
        if ownershipChanged { reload() }
    }

    /// When LogiCam Tuner quits, return Smart Auto's features to the camera's own automatics so the
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
        guard let info = selectedUVC else { presetNames = []; startupPreset = nil; return }
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
        guard let info = selectedUVC else { return }
        do { try store.delete(named: name, for: info) } catch { errorMessage = "\(error)" }
        reloadPresets()
    }

    func setStartupPreset(_ name: String?) {
        guard let info = selectedUVC else { return }
        do { try store.setStartupPreset(name, for: info) } catch { errorMessage = "\(error)" }
        reloadPresets()
    }

    private func applyStartupPreset(_ info: CameraInfo) {
        guard let name = store.startupPreset(for: info), let preset = store.presets(for: info)[name] else { return }
        let owned = store.smartAuto(for: info).ownedControls
        io.async { [weak self] in
            guard let camera = try? Camera(info) else { return }
            _ = preset.apply(to: camera, skipping: owned)
            DispatchQueue.main.async { if self?.selectedUVC == info { self?.reload() } }
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
