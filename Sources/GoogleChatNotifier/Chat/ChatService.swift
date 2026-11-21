import Foundation

/// Thin wrapper over the Google Chat REST endpoints we call.
final class ChatService {
    private let api: GoogleAPIClient
    private let base = "https://chat.googleapis.com/v1"

    init(api: GoogleAPIClient) {
        self.api = api
    }

    /// All spaces (DMs, group chats, named spaces) the user is a member of.
    func listSpaces() async throws -> [ChatSpace] {
        var all: [ChatSpace] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await api.get(ListSpacesResponse.self, "\(base)/spaces", query: query)
            all.append(contentsOf: page.spaces ?? [])
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
        } while pageToken != nil
        return all
    }

    /// Messages in `space` created strictly after `after` (an RFC 3339 timestamp), oldest first.
    func listMessages(space: String, after: String, maxPages: Int = 5) async throws -> [ChatMessage] {
        var all: [ChatMessage] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [
                URLQueryItem(name: "pageSize", value: "100"),
                // Default ordering is oldest first.
                URLQueryItem(name: "filter", value: "createTime > \"\(after)\""),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await api.get(ListMessagesResponse.self, "\(base)/\(space)/messages", query: query)
            all.append(contentsOf: page.messages ?? [])
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
            pages += 1
        } while pageToken != nil && pages < maxPages
        return all
    }

    /// When the signed-in user last read `space` (on any device).
    func readState(space: String) async throws -> SpaceReadState {
        try await api.get(SpaceReadState.self, "\(base)/users/me/\(space)/spaceReadState")
    }
}

/// Resolves `users/{id}` to a display name via the People API, with caching.
/// (With user authentication, Chat API doesn't include human senders' names.)
actor PeopleDirectory {
    private let api: GoogleAPIClient
    private var cache: [String: String]
    private var failures: [String: Date] = [:]
    private static let cacheKey = "peopleNameCache"

    init(api: GoogleAPIClient) {
        self.api = api
        cache = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
    }

    func displayName(for user: ChatUser?) async -> String? {
        guard let user else { return nil }
        if let name = user.displayName, !name.isEmpty { return name }
        guard let resource = user.name, resource.hasPrefix("users/") else { return nil }
        if let cached = cache[resource] { return cached }
        if let failedAt = failures[resource], Date().timeIntervalSince(failedAt) < 3600 { return nil }

        let id = String(resource.dropFirst("users/".count))
        do {
            let person = try await api.get(
                PeoplePerson.self,
                "https://people.googleapis.com/v1/people/\(id)",
                query: [
                    URLQueryItem(name: "personFields", value: "names,emailAddresses"),
                    URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_PROFILE"),
                    URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_DOMAIN_CONTACT"),
                    URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_CONTACT"),
                ]
            )
            let name = person.names?.compactMap(\.displayName).first(where: { !$0.isEmpty })
                ?? person.emailAddresses?.compactMap(\.value).first
            if let name {
                cache[resource] = name
                UserDefaults.standard.set(cache, forKey: Self.cacheKey)
            } else {
                failures[resource] = Date()
            }
            return name
        } catch {
            failures[resource] = Date()
            return nil
        }
    }

    func clear() {
        cache = [:]
        failures = [:]
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }
}
