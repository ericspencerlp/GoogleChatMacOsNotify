import AppKit
import SwiftUI

/// Hosts the SwiftUI settings view in a normal window. (A menu-bar-only app has no
/// main window, so we manage this one ourselves.)
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Google Chat Notifier"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
