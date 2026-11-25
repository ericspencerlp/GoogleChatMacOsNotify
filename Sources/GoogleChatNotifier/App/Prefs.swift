import AppKit
import Foundation

/// UserDefaults keys and typed accessors for user-facing settings.
enum Prefs {
    static let pollInterval = "pollIntervalSeconds"
    static let notifyMode = "notifyMode"
    static let soundName = "soundName"
    static let showPreview = "showMessagePreview"
    static let includeBots = "includeBotMessages"
    static let paused = "notificationsPaused"
    static let reminderInterval = "reminderIntervalSeconds"
    static let flashIcon = "flashMenuBarIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            pollInterval: 30.0,
            notifyMode: NotifyMode.all.rawValue,
            soundName: "Default",
            showPreview: true,
            includeBots: true,
            paused: false,
            reminderInterval: 60.0,
            flashIcon: true,
        ])
    }

    static var pollIntervalSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: pollInterval)
        return value >= 10 ? value : 30
    }

    /// How often to replay the sound while messages are unseen; 0 = never.
    static var reminderIntervalSeconds: TimeInterval {
        max(0, UserDefaults.standard.double(forKey: reminderInterval))
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

/// Sounds offered in Settings. The app plays the sound itself (rather than attaching it to the
/// notification) so it is heard reliably and can be repeated while messages are unseen.
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

    @MainActor
    static func play(_ name: String) {
        switch name {
        case none: return
        case systemDefault: NSSound.beep()
        default:
            guard let sound = NSSound(named: NSSound.Name(name)) else { return NSSound.beep() }
            sound.stop()
            sound.play()
        }
    }
}
