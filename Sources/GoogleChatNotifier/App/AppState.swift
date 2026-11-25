import AppKit
import Combine
import Foundation

/// Central, observable app state shared by the menu bar UI and Settings window.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isConfigured = false
    @Published private(set) var account: GoogleUserInfo?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var recent: [IncomingMessage] = []
    @Published private(set) var unseen: [IncomingMessage] = []
    var unseenCount: Int { unseen.count }
    /// Toggled while the menu bar icon is flashing; false when steady.
    @Published private(set) var flashPhase = false
    @Published var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: Prefs.paused)
            if isPaused { stopAttention() } else if unseenCount > 0 { startReminders() }
        }
    }

    private let auth = AuthService.shared
    private let api: GoogleAPIClient
    private let chat: ChatService
    private let people: PeopleDirectory
    private let poller: ChatPoller
    private var pollTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    private init() {
        api = GoogleAPIClient(auth: AuthService.shared)
        chat = ChatService(api: api)
        people = PeopleDirectory(api: api)
        poller = ChatPoller(chat: chat, people: people)
        isPaused = UserDefaults.standard.bool(forKey: Prefs.paused)
    }

    // MARK: - Derived UI state

    var menuBarSymbol: String {
        if !isConfigured || account == nil { return "bubble.left.and.exclamationmark.bubble.right" }
        if isPaused { return "bell.slash" }
        return unseenCount > 0 ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
    }

    /// The icon is drawn in color while there are unseen messages, blinking off during a flash.
    var menuBarIsHighlighted: Bool {
        account != nil && !isPaused && unseenCount > 0 && !flashPhase
    }

    var statusText: String {
        if !isConfigured { return "Setup required — open Settings" }
        if isSigningIn { return "Waiting for Google sign-in…" }
        if account == nil { return "Not signed in" }
        if let lastError { return "⚠︎ \(lastError)" }
        if isPaused { return "Notifications paused" }
        if let lastChecked {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Last checked at \(formatter.string(from: lastChecked))"
        }
        return isChecking ? "Checking…" : "Starting…"
    }

    // MARK: - Lifecycle

    func start() async {
        isConfigured = await auth.clientConfig() != nil
        account = await auth.currentUser
        if account != nil { startPolling() }
    }

    func checkNow() {
        guard account != nil else { return }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var failures = 0
            while !Task.isCancelled {
                let ok = await self.pollOnce()
                failures = ok ? 0 : failures + 1
                let interval: TimeInterval = ok
                    ? Prefs.pollIntervalSeconds
                    : min(600, Prefs.pollIntervalSeconds * pow(2, Double(min(failures, 5))))
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return // cancelled
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Returns true on success.
    private func pollOnce() async -> Bool {
        guard let account = await auth.currentUser else {
            self.account = nil
            stopPolling()
            return false
        }
        isChecking = true
        defer { isChecking = false }

        do {
            let updates = try await poller.poll(account: account, settings: .current)
            lastChecked = Date()
            lastError = nil
            await dropMessagesReadElsewhere()
            deliver(updates)
            return true
        } catch AuthError.invalidGrant {
            self.account = nil
            lastError = AuthError.invalidGrant.errorDescription
            Notifier.shared.postSignInRequired()
            stopPolling()
            return false
        } catch AuthError.notSignedIn {
            self.account = nil
            stopPolling()
            return false
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                return true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    private func deliver(_ updates: [SpaceUpdate]) {
        guard !updates.isEmpty else { return }
        let settings = NotifySettings.current
        for update in updates {
            recent.insert(contentsOf: update.messages.reversed(), at: 0)
            unseen.append(contentsOf: update.messages)
            if !isPaused {
                Notifier.shared.post(update, settings: settings)
            }
        }
        recent.sort { $0.createTime > $1.createTime }
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        if !isPaused {
            alert()
            startReminders()
        }
    }

    /// Messages read in Google Chat itself (web, phone) count as seen, which stops the reminders.
    private func dropMessagesReadElsewhere() async {
        guard !unseen.isEmpty else { return }
        let lastRead = await poller.lastReadTimes(spaces: Set(unseen.map(\.spaceName)))
        let remaining = unseen.filter { message in
            guard let read = lastRead[message.spaceName] else { return true }
            return message.createTime > read
        }
        if remaining.isEmpty {
            markAllSeen()
        } else if remaining.count != unseen.count {
            unseen = remaining
        }
    }

    // MARK: - Attention (sound, repeat, flashing icon)

    private func alert() {
        SoundCatalog.play(NotifySettings.current.soundName)
        flashIcon()
    }

    /// How long reminders keep repeating after the most recent new message.
    private static let reminderWindow: TimeInterval = 5 * 60

    /// Replays the alert every `Prefs.reminderIntervalSeconds` until messages are marked seen,
    /// for at most `reminderWindow`. Called on every new message, which restarts the window.
    private func startReminders() {
        reminderTask?.cancel()
        reminderTask = nil
        let interval = Prefs.reminderIntervalSeconds
        guard interval > 0 else { return }
        let deadline = Date().addingTimeInterval(Self.reminderWindow)
        reminderTask = Task { @MainActor in
            while !Task.isCancelled, Date().addingTimeInterval(interval) <= deadline {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return // cancelled
                }
                guard self.unseenCount > 0, !self.isPaused else { return }
                self.alert()
            }
        }
    }

    private func flashIcon() {
        guard UserDefaults.standard.bool(forKey: Prefs.flashIcon) else { return }
        flashTask?.cancel()
        flashPhase = false
        flashTask = Task { @MainActor in
            for _ in 0..<12 { // even count, so it ends on the steady colored icon
                self.flashPhase.toggle()
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                } catch {
                    return // cancelled; whoever cancelled resets flashPhase
                }
            }
        }
    }

    private func stopAttention() {
        reminderTask?.cancel()
        reminderTask = nil
        flashTask?.cancel()
        flashTask = nil
        flashPhase = false
    }

    // MARK: - User actions

    func open(_ message: IncomingMessage) {
        NSWorkspace.shared.open(message.url)
        markAllSeen()
    }

    func openGoogleChat() {
        if let url = URL(string: "https://chat.google.com/") {
            NSWorkspace.shared.open(url)
        }
        markAllSeen()
    }

    func markAllSeen() {
        unseen.removeAll()
        stopAttention()
        Notifier.shared.removeAllDelivered()
    }

    /// Empties the "Recent" list in the menu (and clears delivered notifications).
    /// Doesn't affect Google Chat itself; only messages arriving after this will show up.
    func clearRecent() {
        recent.removeAll()
        markAllSeen()
    }

    func saveClientConfig(_ config: OAuthClientConfig) async throws {
        try await auth.setClientConfig(config)
        isConfigured = true
        lastError = nil
    }

    func importClientJSON(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let config = try OAuthClientConfig.fromGoogleJSON(data)
        try await saveClientConfig(config)
    }

    func currentClientID() async -> String? {
        await auth.clientConfig()?.clientID
    }

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        Task { @MainActor in
            defer { self.isSigningIn = false }
            do {
                let user = try await self.auth.signIn()
                self.account = user
                self.startPolling()
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError {
                // User cancelled.
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        Task { await auth.cancelSignIn() }
    }

    func signOut() {
        stopPolling()
        Task { @MainActor in
            await self.auth.signOut()
            await self.poller.reset()
            await self.people.clear()
            self.account = nil
            self.recent = []
            self.markAllSeen()
            self.lastChecked = nil
            self.lastError = nil
        }
    }
}
