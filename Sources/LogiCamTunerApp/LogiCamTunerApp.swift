import AppKit
import SwiftUI

@main
struct LogiCamTunerApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        // Runs before the model reads any preference.
        Self.migrateLegacyPreferences()
    }

    /// Copies preferences saved under the app's earlier name (CamDial) once.
    private static func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromCamDial") else { return }
        defaults.set(true, forKey: "migratedFromCamDial")
        guard let legacy = UserDefaults(suiteName: "io.github.camdial") else { return }
        for key in ["frameRate", "overlayMode", "mirrorPreview"] where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        if let frame = legacy.string(forKey: "NSWindow Frame CamDialOverlay") {
            defaults.set(frame, forKey: "NSWindow Frame LogiCamTunerOverlay")
        }
    }

    var body: some Scene {
        Window("LogiCam Tuner", id: Self.mainWindowID) {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1120, height: 700)

        MenuBarExtra("LogiCam Tuner", systemImage: "web.camera") {
            MenuView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Smart Auto keeps serving video apps after the window closes; quit from the menu-bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
