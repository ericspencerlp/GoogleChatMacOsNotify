import SwiftUI

/// The drop-down menu shown when clicking the menu bar icon.
struct MenuContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Text(state.statusText)
        if let email = state.account?.email {
            Text(email)
        }

        Divider()

        if state.account != nil {
            if state.recent.isEmpty {
                Text("No new messages since launch")
            } else {
                Text(state.unseenCount > 0 ? "Recent — \(state.unseenCount) unseen" : "Recent")
                ForEach(state.recent.prefix(10)) { message in
                    Button {
                        state.open(message)
                    } label: {
                        Text(menuTitle(for: message))
                    }
                }
                Button("Mark All as Seen") { state.markAllSeen() }
                    .disabled(state.unseenCount == 0)
                Button("Clear Recent Messages") { state.clearRecent() }
                    .keyboardShortcut(.delete)
            }

            Divider()

            Button("Check Now") { state.checkNow() }
                .keyboardShortcut("r")
            Toggle("Pause Notifications", isOn: $state.isPaused)
            Button("Open Google Chat") { state.openGoogleChat() }
                .keyboardShortcut("o")
        } else {
            Button(state.isConfigured ? "Sign In…" : "Set Up…") {
                SettingsWindowController.shared.show()
            }
        }

        Divider()

        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Quit Google Chat Notifier") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuTitle(for message: IncomingMessage) -> String {
        let who = message.spaceTitle == message.senderName
            ? message.senderName
            : "\(message.spaceTitle) · \(message.senderName)"
        let text = message.text.replacingOccurrences(of: "\n", with: " ")
        let snippet = text.count > 50 ? String(text.prefix(49)) + "…" : text
        return "\(who): \(snippet)"
    }
}
