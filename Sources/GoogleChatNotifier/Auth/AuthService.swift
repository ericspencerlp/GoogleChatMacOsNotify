import AppKit
import Foundation

/// The OAuth client created in Google Cloud Console ("Desktop app" type).
struct OAuthClientConfig: Codable, Equatable, Sendable {
    var clientID: String
    var clientSecret: String

    /// Parses the JSON file Google Cloud Console lets you download for an OAuth client.
    /// Format: {"installed": {"client_id": "...", "client_secret": "...", ...}}
    static func fromGoogleJSON(_ data: Data) throws -> OAuthClientConfig {
        struct Inner: Decodable {
            let client_id: String
            let client_secret: String?
        }
        struct Outer: Decodable {
            let installed: Inner?
            let web: Inner?
        }
        let outer = try JSONDecoder().decode(Outer.self, from: data)
        guard let inner = outer.installed ?? outer.web else {
            throw AuthError.invalidClientFile
        }
        return OAuthClientConfig(clientID: inner.client_id, clientSecret: inner.client_secret ?? "")
    }
}

struct GoogleUserInfo: Codable, Equatable, Sendable {
    /// Stable Google account ID. Google Chat identifies this user as `users/{sub}`.
    let sub: String
    let email: String?
    let name: String?

    var chatResourceName: String { "users/\(sub)" }
}

enum AuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case invalidClientFile
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case invalidGrant
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Google OAuth client is configured. Import your client JSON in Settings → Account."
        case .notSignedIn: return "Not signed in to Google."
        case .invalidClientFile: return "That file doesn't look like a Google OAuth client JSON (expected an \"installed\" section)."
        case .stateMismatch: return "Sign-in response didn't match the request. Please try again."
        case .authorizationDenied(let reason): return "Google sign-in was not completed: \(reason)"
        case .tokenExchangeFailed(let reason): return "Couldn't get tokens from Google: \(reason)"
        case .invalidGrant: return "Your Google sign-in has expired or was revoked. Please sign in again."
        case .timedOut: return "Timed out waiting for the browser sign-in to finish."
        }
    }
}

private struct StoredTokens: Codable {
    var accessToken: String?
    var accessTokenExpiry: Date?
    var refreshToken: String
    var user: GoogleUserInfo
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int?
    let refresh_token: String?
}

private struct TokenErrorResponse: Decodable {
    let error: String?
    let error_description: String?
}

/// Handles the OAuth 2.0 loopback + PKCE flow, token storage (Keychain) and refresh.
actor AuthService {
    static let shared = AuthService()

    static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/chat.spaces.readonly",
        "https://www.googleapis.com/auth/chat.messages.readonly",
        "https://www.googleapis.com/auth/chat.users.readstate.readonly",
        "https://www.googleapis.com/auth/directory.readonly",
    ]

    private static let clientAccount = "oauth-client"
    private static let tokenAccount = "oauth-tokens"

    private var tokens: StoredTokens?
    private var refreshTask: Task<String, Error>?
    private var activeServer: LoopbackServer?

    init() {
        tokens = Keychain.getCodable(StoredTokens.self, account: Self.tokenAccount)
    }

    // MARK: - Client configuration

    func clientConfig() -> OAuthClientConfig? {
        Keychain.getCodable(OAuthClientConfig.self, account: Self.clientAccount)
    }

    func setClientConfig(_ config: OAuthClientConfig) throws {
        try Keychain.setCodable(config, account: Self.clientAccount)
    }

    var currentUser: GoogleUserInfo? { tokens?.user }

    // MARK: - Sign in / out

    func signIn() async throws -> GoogleUserInfo {
        guard let config = clientConfig() else { throw AuthError.notConfigured }

        activeServer?.cancel()
        let server = LoopbackServer()
        activeServer = server
        defer {
            server.stop()
            if activeServer === server { activeServer = nil }
        }

        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let verifier = PKCE.makeVerifier()
        let state = PKCE.randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else { throw URLError(.badURL) }

        // Opens in the user's default browser, where they're likely already signed in to Google.
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let params = try await server.waitForCallback(timeout: 300)
        if let error = params["error"] { throw AuthError.authorizationDenied(error) }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"], !code.isEmpty else {
            throw AuthError.authorizationDenied("no authorization code returned")
        }

        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        guard let refreshToken = response.refresh_token else {
            throw AuthError.tokenExchangeFailed("Google did not return a refresh token")
        }

        let user = try await fetchUserInfo(accessToken: response.access_token)
        let stored = StoredTokens(
            accessToken: response.access_token,
            accessTokenExpiry: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
            refreshToken: refreshToken,
            user: user
        )
        tokens = stored
        try Keychain.setCodable(stored, account: Self.tokenAccount)
        return user
    }

    func cancelSignIn() {
        activeServer?.cancel()
    }

    func signOut() async {
        let refreshToken = tokens?.refreshToken
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        Keychain.delete(Self.tokenAccount)

        // Best-effort revoke so the grant disappears from the user's Google account.
        if let refreshToken,
           let url = URL(string: "https://oauth2.googleapis.com/revoke") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncode(["token": refreshToken]).utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Access tokens

    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if let token = tokens.accessToken,
           let expiry = tokens.accessTokenExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await self.refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Forces the next `validAccessToken()` call to refresh (used after a 401).
    func discardAccessToken() {
        tokens?.accessToken = nil
        tokens?.accessTokenExpiry = nil
    }

    private func refreshAccessToken() async throws -> String {
        guard let config = clientConfig() else { throw AuthError.notConfigured }
        guard let current = tokens else { throw AuthError.notSignedIn }
        do {
            let response = try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
            ])
            // The user may have signed out while we were waiting.
            guard var updated = tokens, updated.refreshToken == current.refreshToken else {
                throw AuthError.notSignedIn
            }
            updated.accessToken = response.access_token
            updated.accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
            if let newRefresh = response.refresh_token { updated.refreshToken = newRefresh }
            tokens = updated
            try? Keychain.setCodable(updated, account: Self.tokenAccount)
            return response.access_token
        } catch AuthError.invalidGrant {
            tokens = nil
            Keychain.delete(Self.tokenAccount)
            throw AuthError.invalidGrant
        }
    }

    // MARK: - HTTP helpers

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(params).utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let err = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            if err?.error == "invalid_grant" { throw AuthError.invalidGrant }
            let reason = err?.error_description ?? err?.error ?? "HTTP \(status)"
            throw AuthError.tokenExchangeFailed(reason)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchUserInfo(accessToken: String) async throws -> GoogleUserInfo {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.tokenExchangeFailed("couldn't read your Google profile (HTTP \(status))")
        }
        return try JSONDecoder().decode(GoogleUserInfo.self, from: data)
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
    }
}
