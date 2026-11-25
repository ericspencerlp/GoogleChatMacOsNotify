import AppKit
import UserNotifications

/// Posts native macOS notifications (Notification Center) and opens the
/// conversation in Google Chat when one is clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// UNUserNotificationCenter requires a real app bundle; it crashes under `swift run`.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func configure() {
        center?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(_ update: SpaceUpdate, settings: NotifySettings) {
        guard let center, let last = update.messages.last else { return }

        let content = UNMutableNotificationContent()
        let count = update.messages.count

        // DMs: title is the sender. Spaces/group chats: title is the space, subtitle the sender.
        content.title = update.spaceTitle
        if update.spaceTitle != last.senderName {
            content.subtitle = last.senderName
        }

        if settings.showPreview {
            let text = Self.truncate(last.text, to: 240)
            content.body = count > 1 ? "\(count) new messages — latest: \(text)" : text
        } else {
            content.body = count > 1 ? "\(count) new messages" : "New message"
        }

        content.sound = nil  // AppState plays (and repeats) the sound itself.
        content.threadIdentifier = update.spaceName          // groups notifications per conversation
        content.userInfo = ["url": last.url.absoluteString]
        content.interruptionLevel = .active

        let request = UNNotificationRequest(identifier: last.id, content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("GoogleChatNotifier: failed to post notification: \(error)") }
        }
    }

    /// Shown when the user's Google session expires and they need to sign in again.
    func postSignInRequired() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Google Chat Notifier"
        content.body = "Your Google sign-in expired. Open Settings from the menu bar icon to sign in again."
        content.userInfo = ["action": "settings"]
        center.add(UNNotificationRequest(identifier: "sign-in-required", content: content, trigger: nil))
    }

    func removeAllDelivered() {
        center?.removeAllDeliveredNotifications()
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even when the app counts as "active" (menu open, Settings open).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let urlString = info["url"] as? String
        let action = info["action"] as? String
        Task { @MainActor in
            if action == "settings" {
                SettingsWindowController.shared.show()
            } else if let urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                AppState.shared.markAllSeen()
            }
        }
        completionHandler()
    }
}
