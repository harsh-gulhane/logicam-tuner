import AppKit
import CoreAudio
import Darwin

/// An app believed to be using the camera, and why.
public struct CameraUser: Equatable, Sendable {
    public enum Evidence: String, Sendable {
        /// The app is also capturing audio, as video-call apps do.
        case microphone
        /// No app is capturing audio; this is the frontmost app known to use cameras.
        case frontmost
    }

    public let name: String
    public let bundleID: String?
    public let evidence: Evidence
}

/// Guesses which app is using the camera.
///
/// macOS has no public API that names camera clients (CoreMediaIO only says whether a device is
/// running somewhere). CoreAudio does name the processes capturing audio, and video-call apps
/// capture the microphone along with the camera, so those apps are reported first.
public enum CameraUsers {
    /// Every app that is probably using the camera: those also capturing audio or, when none is,
    /// the frontmost app known to use cameras.
    public static func likelyUsers(excluding excludedPID: pid_t = getpid()) -> [CameraUser] {
        let capturing = audioCapturingApps(excluding: excludedPID)
        if !capturing.isEmpty { return capturing }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != excludedPID,
              let id = front.bundleIdentifier, knownCameraApps.contains(id) else { return [] }
        return [CameraUser(name: front.localizedName ?? id, bundleID: id, evidence: .frontmost)]
    }

    /// Apps with a process capturing audio input, deduplicated by owning app.
    public static func audioCapturingApps(excluding excludedPID: pid_t = getpid()) -> [CameraUser] {
        var seen = Set<String>()
        return processObjects().compactMap { object -> CameraUser? in
            guard property(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
                  let pid = property(object, kAudioProcessPropertyPID, pid_t(0)), pid != excludedPID,
                  let app = owningApp(pid: pid), seen.insert(app.bundleID ?? app.name).inserted else { return nil }
            return app
        }
    }

    /// Apps commonly used with a webcam, for the fallback when no app captures audio.
    static let knownCameraApps: Set<String> = [
        "com.apple.FaceTime", "com.apple.PhotoBooth", "com.apple.QuickTimePlayerX", "com.apple.Safari",
        "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "net.whatsapp.WhatsApp",
        "WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.obsproject.obs-studio",
        "com.cisco.webexmeetingsapp", "com.skype.skype", "com.loom.desktop", "ru.keepcoder.Telegram",
    ]

    /// System processes that capture on behalf of an app.
    static let daemonOwners: [String: CameraUser] = [
        "avconferenced": CameraUser(name: "FaceTime", bundleID: "com.apple.FaceTime", evidence: .microphone),
    ]

    /// The outermost .app bundle containing the process, so helpers (e.g. "Google Chrome Helper")
    /// are reported as their app.
    static func owningApp(pid: pid_t) -> CameraUser? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        if let daemon = daemonOwners[(path as NSString).lastPathComponent] { return daemon }
        guard let appPath = outermostApp(path), let bundle = Bundle(path: appPath) else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return CameraUser(name: name, bundleID: bundle.bundleIdentifier, evidence: .microphone)
    }

    static func outermostApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == 0 else { return [] }
        return objects
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                     _ initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == 0 ? value : nil
    }
}
