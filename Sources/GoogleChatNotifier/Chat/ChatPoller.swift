import Foundation
import os

/// A new message ready to show to the user.
struct IncomingMessage: Identifiable, Sendable {
    let id: String              // message resource name
    let spaceName: String
    let spaceTitle: String
    let senderName: String
    let text: String
    let createTime: Date
    let url: URL
}

/// New messages for one space found in a single poll.
struct SpaceUpdate: Sendable {
    let spaceName: String
    let spaceTitle: String
    let isDirect: Bool
    let messages: [IncomingMessage]
}

/// Persisted polling state: per-space watermarks so we only fetch messages we haven't seen.
private struct PollerState: Codable {
    struct SpaceState: Codable {
        /// createTime of the newest message already processed (exact string from the API).
        var watermark: String
        /// Space.lastActiveTime when we last processed this space.
        var lastActiveTime: String?
    }

    var accountID: String?
    var initialized = false
    var lastPollStart: String?
    var spaces: [String: SpaceState] = [:]
    var recentMessageIDs: [String] = []
}

/// Polls Google Chat efficiently:
///  1. One `spaces.list` call per cycle.
///  2. Only spaces whose `lastActiveTime` changed are queried for new messages.
///  3. Messages the user sent, already read elsewhere, or filtered out by settings are skipped.
actor ChatPoller {
    private let chat: ChatService
    private let people: PeopleDirectory
    private var state: PollerState
    private let log = Logger(subsystem: "com.lendingpad.GoogleChatNotifier", category: "poller")

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GoogleChatNotifier", isDirectory: true)
            .appendingPathComponent("poller-state.json")
    }

    init(chat: ChatService, people: PeopleDirectory) {
        self.chat = chat
        self.people = people
        if let data = try? Data(contentsOf: Self.stateURL),
           let saved = try? JSONDecoder().decode(PollerState.self, from: data) {
            state = saved
        } else {
            state = PollerState()
        }
    }

    func reset() {
        state = PollerState()
        try? FileManager.default.removeItem(at: Self.stateURL)
    }

    func poll(account: GoogleUserInfo, settings: NotifySettings) async throws -> [SpaceUpdate] {
        if state.accountID != account.sub {
            state = PollerState()
            state.accountID = account.sub
        }

        let pollStartDate = Date()
        let pollStart = RFC3339.string(from: pollStartDate)
        let me = account.chatResourceName
        let isFirstRun = !state.initialized
        let spaces = try await chat.listSpaces()

        var updates: [SpaceUpdate] = []
        var recentIDs = state.recentMessageIDs
        var seen = Set(recentIDs)

        for space in spaces {
            var spaceState: PollerState.SpaceState
            if let existing = state.spaces[space.name] {
                spaceState = existing
            } else if isFirstRun {
                // First launch: start from "now" so we don't replay history.
                state.spaces[space.name] = .init(watermark: pollStart, lastActiveTime: space.lastActiveTime)
                continue
            } else {
                // A space we haven't seen before (e.g. someone just started a DM with you).
                // Look back a little before the previous poll to tolerate clock skew.
                let lookBackFrom = state.lastPollStart.flatMap(RFC3339.parse) ?? pollStartDate
                spaceState = .init(watermark: RFC3339.string(from: lookBackFrom.addingTimeInterval(-300)),
                                   lastActiveTime: nil)
            }

            // Nothing happened since last time.
            if let active = space.lastActiveTime, active == spaceState.lastActiveTime { continue }
            if let active = space.lastActiveTime.flatMap(RFC3339.parse),
               let watermark = RFC3339.parse(spaceState.watermark),
               active <= watermark {
                spaceState.lastActiveTime = space.lastActiveTime
                state.spaces[space.name] = spaceState
                continue
            }

            let messages: [ChatMessage]
            do {
                messages = try await chat.listMessages(space: space.name, after: spaceState.watermark)
            } catch let error as GoogleAPIError where [403, 404].contains(error.statusCode) {
                // Space we can't read (left, deleted, restricted). Remember it so we don't retry every cycle.
                log.notice("Skipping \(space.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                spaceState.lastActiveTime = space.lastActiveTime
                state.spaces[space.name] = spaceState
                continue
            }

            let sorted = messages
                .compactMap { message -> (ChatMessage, String, Date)? in
                    guard let created = message.createTime, let date = RFC3339.parse(created) else { return nil }
                    return (message, created, date)
                }
                .sorted { $0.2 < $1.2 }

            if let newest = sorted.last { spaceState.watermark = newest.1 }
            spaceState.lastActiveTime = space.lastActiveTime
            state.spaces[space.name] = spaceState

            var candidates = sorted.filter { item in
                let message = item.0
                guard !seen.contains(message.name) else { return false }
                guard message.sender?.name != me else { return false }
                if !settings.includeBots && message.sender?.type == "BOT" { return false }
                if settings.mode == .directAndMentions && !space.isDirect && !message.mentions(userResourceName: me) {
                    return false
                }
                return true
            }
            for item in sorted {
                if seen.insert(item.0.name).inserted {
                    recentIDs.append(item.0.name)
                }
            }
            guard !candidates.isEmpty else { continue }

            // Skip anything already read on another device (phone, another computer, web).
            if let readState = try? await chat.readState(space: space.name),
               let lastRead = readState.lastReadTime.flatMap(RFC3339.parse) {
                candidates = candidates.filter { $0.2 > lastRead }
            }
            guard !candidates.isEmpty else { continue }

            let url = URL(string: space.spaceUri ?? "") ?? URL(string: "https://chat.google.com/")!
            var incoming: [IncomingMessage] = []
            for (message, _, date) in candidates {
                let sender = await people.displayName(for: message.sender) ?? "Someone"
                incoming.append(IncomingMessage(
                    id: message.name,
                    spaceName: space.name,
                    spaceTitle: title(for: space, sender: sender),
                    senderName: sender,
                    text: message.previewText,
                    createTime: date,
                    url: url
                ))
            }
            updates.append(SpaceUpdate(
                spaceName: space.name,
                spaceTitle: incoming.last?.spaceTitle ?? "Google Chat",
                isDirect: space.isDirect,
                messages: incoming
            ))
        }

        // Forget spaces the user is no longer in.
        let current = Set(spaces.map(\.name))
        state.spaces = state.spaces.filter { current.contains($0.key) }

        state.recentMessageIDs = Array(recentIDs.suffix(1000))
        state.initialized = true
        state.lastPollStart = pollStart
        save()
        return updates
    }

    private func title(for space: ChatSpace, sender: String) -> String {
        if space.isDirectMessage { return sender }
        if let name = space.displayName, !name.isEmpty { return name }
        return space.isGroupChat ? "Group conversation" : "Google Chat"
    }

    private func save() {
        do {
            let url = Self.stateURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            log.error("Failed to save poller state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
