import AppKit
import SwiftUI

@main
struct OpenHeadPointerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: AppModel.shared)
        } label: {
            Image(systemName: AppModel.shared.controlEnabled ? "eye.fill" : "eye")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        if CommandLine.arguments.contains("--debug-window") {
            DebugWindowController.shared.show()
        }
    }
}
