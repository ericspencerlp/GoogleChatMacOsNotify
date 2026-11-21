import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            GeneralSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Notifications tab

struct GeneralSettingsView: View {
    @AppStorage(Prefs.pollInterval) private var pollInterval: Double = 30
    @AppStorage(Prefs.notifyMode) private var notifyMode: String = NotifyMode.all.rawValue
    @AppStorage(Prefs.soundName) private var soundName: String = SoundCatalog.systemDefault
    @AppStorage(Prefs.showPreview) private var showPreview = true
    @AppStorage(Prefs.includeBots) private var includeBots = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    private let sounds = SoundCatalog.names

    var body: some View {
        Form {
            Section {
                Picker("Notify me about", selection: $notifyMode) {
                    ForEach(NotifyMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Toggle("Show message text in notifications", isOn: $showPreview)
                Toggle("Include messages from bots and apps", isOn: $includeBots)
            }

            Section {
                HStack {
                    Picker("Sound", selection: $soundName) {
                        ForEach(sounds, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        playPreview()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .help("Preview sound")
                    .disabled(soundName == SoundCatalog.none)
                }
                Picker("Check for new messages", selection: $pollInterval) {
                    Text("Every 15 seconds").tag(15.0)
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                }
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
                Button("Open macOS Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Banner style, Focus modes and lock-screen behaviour are controlled in System Settings → Notifications → Google Chat Notifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func playPreview() {
        if soundName == SoundCatalog.systemDefault {
            NSSound.beep()
        } else {
            NSSound(named: NSSound.Name(soundName))?.play()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Account tab

struct AccountSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var savedClientID: String?
    @State private var showManualEntry = false
    @State private var configError: String?

    var body: some View {
        Form {
            Section {
                if let savedClientID {
                    LabeledContent("OAuth client") {
                        Text(Self.abbreviate(savedClientID))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Import the OAuth client JSON you downloaded from Google Cloud Console (see README).")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(savedClientID == nil ? "Import Client JSON…" : "Replace Client JSON…") {
                        importJSON()
                    }
                    Button(showManualEntry ? "Hide Manual Entry" : "Enter Manually…") {
                        showManualEntry.toggle()
                    }
                    .buttonStyle(.link)
                }
                if showManualEntry {
                    TextField("Client ID", text: $clientID)
                    SecureField("Client secret", text: $clientSecret)
                    Button("Save Client") { saveManual() }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let configError {
                    Text(configError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Google Cloud OAuth Client")
            }

            Section {
                if let account = state.account {
                    LabeledContent("Signed in as") {
                        Text(account.email ?? account.name ?? account.sub)
                    }
                    Button("Sign Out", role: .destructive) { state.signOut() }
                } else if state.isSigningIn {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…")
                        Spacer()
                        Button("Cancel") { state.cancelSignIn() }
                    }
                } else {
                    Button("Sign In with Google…") { state.signIn() }
                        .disabled(!state.isConfigured)
                        .keyboardShortcut(.defaultAction)
                }
                if let error = state.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Google Account")
            } footer: {
                Text("Read-only access. The app can see your Chat spaces and messages to notify you; it can't send anything. Tokens are stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshClientID() }
    }

    private func refreshClientID() async {
        savedClientID = await state.currentClientID()
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the client_secret_….json file downloaded from Google Cloud Console"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await state.importClientJSON(from: url)
                configError = nil
                await refreshClientID()
            } catch {
                configError = error.localizedDescription
            }
        }
    }

    private func saveManual() {
        let config = OAuthClientConfig(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            do {
                try await state.saveClientConfig(config)
                configError = nil
                clientSecret = ""
                showManualEntry = false
                await refreshClientID()
            } catch {
                configError = error.localizedDescription
            }
        }
    }

    private static func abbreviate(_ id: String) -> String {
        guard id.count > 24 else { return id }
        return String(id.prefix(12)) + "…" + String(id.suffix(28))
    }
}
