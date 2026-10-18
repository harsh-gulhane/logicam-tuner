import AppKit
import SwiftUI

@main
struct CamDialApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("CamDial", id: Self.mainWindowID) {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1120, height: 700)

        MenuBarExtra("CamDial", systemImage: "web.camera") {
            MenuView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Smart Auto keeps serving video apps after the window closes; quit from the menu-bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
