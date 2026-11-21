import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        Notifier.shared.configure()
        Task { _ = await Notifier.shared.requestAuthorization() }

        // After the Mac wakes, give the network a few seconds and then check immediately
        // instead of waiting for the next scheduled poll.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                AppState.shared.checkNow()
            }
        }

        Task { @MainActor in
            await AppState.shared.start()
            // First run (or signed out): show Settings so the user knows what to do.
            if !AppState.shared.isConfigured || AppState.shared.account == nil {
                SettingsWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
