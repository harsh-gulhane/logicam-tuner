import Foundation

/// Where LogiCam Tuner keeps presets, Smart Auto settings and session history.
public enum AppSupport {
    /// ~/Library/Application Support/LogiCam Tuner. Data from the app's earlier name (CamDial) is
    /// moved here the first time it is needed, so renaming loses nothing.
    public static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("LogiCam Tuner", isDirectory: true)
        let legacy = base.appendingPathComponent("CamDial", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }()
}
