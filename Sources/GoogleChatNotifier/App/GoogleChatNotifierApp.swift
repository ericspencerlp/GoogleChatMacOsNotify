import SwiftUI

/// Entry point. The app has no Dock icon (LSUIElement = YES in Info.plist) and lives
/// entirely in the menu bar via `MenuBarExtra`.
@main
struct GoogleChatNotifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.menuBarSymbol)
                .accessibilityLabel("Google Chat Notifier")
        }
        .menuBarExtraStyle(.menu)
    }
}
