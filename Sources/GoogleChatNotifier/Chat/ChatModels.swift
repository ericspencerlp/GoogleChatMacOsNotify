import Foundation

// Subset of the Google Chat REST API v1 resources this app needs.
// https://developers.google.com/workspace/chat/api/reference/rest

struct ChatSpace: Decodable, Hashable, Sendable {
    let name: String               // "spaces/AAAA..."
    let displayName: String?
    let spaceType: String?         // SPACE, GROUP_CHAT, DIRECT_MESSAGE
    let lastActiveTime: String?    // RFC 3339 timestamp of the last message
    let spaceUri: String?          // Link that opens the space in Google Chat

    var isDirectMessage: Bool { spaceType == "DIRECT_MESSAGE" }
    var isGroupChat: Bool { spaceType == "GROUP_CHAT" }
    /// DMs and unnamed group chats count as "direct" for the DM/@mention filter.
    var isDirect: Bool { isDirectMessage || isGroupChat }
}

struct ListSpacesResponse: Decodable {
    let spaces: [ChatSpace]?
    let nextPageToken: String?
}

struct ChatUser: Decodable, Hashable, Sendable {
    let name: String?              // "users/123456789"
    let displayName: String?       // Usually only populated for bots/apps
    let type: String?              // HUMAN or BOT
}

struct ChatUserMention: Decodable, Sendable {
    let user: ChatUser?
    let type: String?
}

struct ChatAnnotation: Decodable, Sendable {
    let type: String?              // USER_MENTION, SLASH_COMMAND, ...
    let userMention: ChatUserMention?
}

struct ChatAttachment: Decodable, Sendable {
    let contentName: String?
}

struct ChatMessage: Decodable, Sendable {
    let name: String               // "spaces/AAAA/messages/BBBB"
    let sender: ChatUser?
    let createTime: String?
    let text: String?
    let annotations: [ChatAnnotation]?
    let attachment: [ChatAttachment]?

    func mentions(userResourceName: String) -> Bool {
        (annotations ?? []).contains { annotation in
            guard annotation.type == "USER_MENTION",
                  let mentioned = annotation.userMention?.user?.name else { return false }
            return mentioned == userResourceName || mentioned == "users/all"
        }
    }

    var previewText: String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let attachment, !attachment.isEmpty {
            if let name = attachment.first?.contentName, !name.isEmpty { return "Sent an attachment: \(name)" }
            return "Sent an attachment"
        }
        return "Sent a message"
    }
}

struct ListMessagesResponse: Decodable {
    let messages: [ChatMessage]?
    let nextPageToken: String?
}

struct SpaceReadState: Decodable {
    let name: String?
    let lastReadTime: String?
}

/// People API person (only the fields we request).
struct PeoplePerson: Decodable {
    struct Name: Decodable { let displayName: String? }
    struct Email: Decodable { let value: String? }
    let names: [Name]?
    let emailAddresses: [Email]?
}

/// RFC 3339 parsing that tolerates any number of fractional-second digits
/// (Google returns microseconds, which ISO8601DateFormatter can't always handle).
enum RFC3339 {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        guard let dot = string.firstIndex(of: ".") else { return plain.date(from: string) }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        let digits = string[string.index(after: dot)..<end]
        let base = String(string[..<dot]) + String(string[end...])
        guard let date = plain.date(from: base) else { return nil }
        let fraction = Double("0." + digits) ?? 0
        return date.addingTimeInterval(fraction)
    }

    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }
}
