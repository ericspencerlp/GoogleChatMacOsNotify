import Foundation

struct GoogleAPIError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        switch statusCode {
        case 403:
            return "Google denied access (403): \(message)"
        case 429:
            return "Google rate limit reached; will retry shortly."
        default:
            return "Google API error \(statusCode): \(message)"
        }
    }
}

private struct GoogleErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }
    let error: Body?
}

/// Authenticated GET helper for Google REST APIs.
final class GoogleAPIClient {
    private let auth: AuthService
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(auth: AuthService, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func get<T: Decodable>(_ type: T.Type = T.self, _ urlString: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(string: urlString) else { throw URLError(.badURL) }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        return try await get(type, url: url, retryOnUnauthorized: true)
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL, retryOnUnauthorized: Bool) async throws -> T {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 && retryOnUnauthorized {
            await auth.discardAccessToken()
            return try await get(type, url: url, retryOnUnauthorized: false)
        }
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(GoogleErrorEnvelope.self, from: data))?.error?.message
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw GoogleAPIError(statusCode: status, message: message)
        }
        return try decoder.decode(T.self, from: data)
    }
}
