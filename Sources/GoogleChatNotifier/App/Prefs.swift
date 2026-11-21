import Foundation
import UserNotifications

/// UserDefaults keys and typed accessors for user-facing settings.
enum Prefs {
    static let pollInterval = "pollIntervalSeconds"
    static let notifyMode = "notifyMode"
    static let soundName = "soundName"
    static let showPreview = "showMessagePreview"
    static let includeBots = "includeBotMessages"
    static let paused = "notificationsPaused"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            pollInterval: 30.0,
            notifyMode: NotifyMode.all.rawValue,
            soundName: "Default",
            showPreview: true,
            includeBots: true,
            paused: false,
        ])
    }

    static var pollIntervalSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: pollInterval)
        return value >= 10 ? value : 30
    }
}

enum NotifyMode: String, CaseIterable, Identifiable {
    case all
    case directAndMentions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All messages"
        case .directAndMentions: return "Direct messages and @mentions only"
        }
    }
}

/// Snapshot of the notification-related settings, safe to pass across actors.
struct NotifySettings: Sendable {
    var mode: NotifyMode
    var soundName: String
    var showPreview: Bool
    var includeBots: Bool

    static var current: NotifySettings {
        let d = UserDefaults.standard
        return NotifySettings(
            mode: NotifyMode(rawValue: d.string(forKey: Prefs.notifyMode) ?? "") ?? .all,
            soundName: d.string(forKey: Prefs.soundName) ?? "Default",
            showPreview: d.bool(forKey: Prefs.showPreview),
            includeBots: d.bool(forKey: Prefs.includeBots)
        )
    }
}

/// Sounds offered in Settings. System sounds are copied into the app bundle by the
/// build script so that `UNNotificationSound(named:)` can find them.
enum SoundCatalog {
    static let none = "None"
    static let systemDefault = "Default"

    static var names: [String] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let system = files
            .filter { $0.pathExtension.lowercased() == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        return [none, systemDefault] + system
    }

    static func notificationSound(for name: String) -> UNNotificationSound? {
        switch name {
        case none: return nil
        case systemDefault: return .default
        default: return UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(name).aiff"))
        }
    }
}
