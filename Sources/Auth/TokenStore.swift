//
//  TokenStore.swift
//  NetworkLayer
//
//  Owns the access/refresh token pair, persists them to Keychain, and —
//  critically — coordinates token refresh so that N concurrent requests
//  hitting a 401 at the same moment trigger exactly ONE refresh call
//  ("refresh storm" prevention), with all N requests then retried using
//  the single new token.
//
//  THREAD SAFETY:
//  This is an `actor` for the same reason as `RequestDeduplicator`: token
//  reads/writes and the refresh-coordination flag must be serialized.
//  Without actor isolation, two requests could both observe
//  "no refresh in progress" and both kick off a network call to the
//  refresh endpoint — exactly the storm we're trying to prevent.
//
//  We reuse the same "store the in-flight Task, let others await it"
//  pattern as `RequestDeduplicator`. It's intentionally not shared code
//  between the two types even though the mechanism is similar: token
//  refresh has different semantics (only ever one key: "the refresh",
//  plus permanent-failure handling that should propagate as `.unauthorized`
//  to force logout) that would make a shared generic abstraction murkier
//  than just repeating ~15 lines of straightforward actor code.
//
import Foundation

public struct AuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    /// Absolute expiry so we can proactively refresh slightly before
    /// expiry (see `TokenAuthenticator`) instead of always waiting for a
    /// reactive 401, which saves one failed round trip per expiry cycle.
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { Date() >= expiresAt }

    /// True if the token is still valid but expiring soon enough that we'd
    /// rather refresh now (in the background) than risk a 401 mid-request.
    public func isExpiringSoon(within window: TimeInterval = 30) -> Bool {
        Date().addingTimeInterval(window) >= expiresAt
    }
}

/// Abstraction over "how do we actually call the refresh endpoint" so
/// `TokenStore` stays decoupled from any specific backend contract, and so
/// tests can inject a fake refresher without spinning up URLSession.
public protocol TokenRefreshing: Sendable {
    func refresh(using refreshToken: String) async throws -> AuthTokens
}

public actor TokenStore {
    private let keychain: KeychainStoring
    private let refresher: TokenRefreshing
    private let accessTokenKey = "auth.tokens.v1"

    private var cachedTokens: AuthTokens?

    /// Holds the in-flight refresh `Task`, if any. Any request that hits a
    /// 401 (or proactively notices near-expiry) while a refresh is already
    /// running will `await` this same task rather than starting another.
    private var refreshTask: Task<AuthTokens, Error>?

    public init(keychain: KeychainStoring, refresher: TokenRefreshing) {
        self.keychain = keychain
        self.refresher = refresher
    }

    /// Loads tokens from Keychain into memory. Call once at app launch.
    /// Subsequent reads are served from the in-memory cache to avoid a
    /// Keychain round trip (which involves IPC to `securityd`) on every
    /// single request.
    public func bootstrap() {
        guard cachedTokens == nil,
              let data = try? keychain.get(accessTokenKey),
              let tokens = try? JSONDecoder.iso8601.decode(AuthTokens.self, from: data) else {
            return
        }
        cachedTokens = tokens
    }

    public func save(_ tokens: AuthTokens) throws {
        cachedTokens = tokens
        let data = try JSONEncoder.iso8601.encode(tokens)
        try keychain.set(data, for: accessTokenKey)
    }

    public func clear() throws {
        cachedTokens = nil
        refreshTask = nil
        try keychain.delete(accessTokenKey)
    }

    /// Returns a currently-valid access token, transparently refreshing it
    /// first if it's missing, expired, or about to expire. Multiple
    /// concurrent callers are coalesced onto a single refresh attempt.
    public func validAccessToken() async throws -> String {
        guard let tokens = cachedTokens else {
            throw NetworkError.unauthorized // No session at all — caller must log in.
        }

        if !tokens.isExpiringSoon() {
            return tokens.accessToken
        }

        return try await performCoalescedRefresh(currentRefreshToken: tokens.refreshToken).accessToken
    }

    /// Called by the APIClient's response interceptor when a request comes
    /// back with 401 despite us believing the token was valid (e.g. the
    /// server's clock disagrees with ours, or the token was revoked
    /// server-side). Forces a refresh and returns the new access token.
    ///
    /// - Parameter staleAccessToken: the token that was actually used on
    ///   the failed request. This guards against a subtle race: if a
    ///   refresh already completed *between* when this request was sent
    ///   and when its 401 came back, we don't want to refresh AGAIN just
    ///   because we're comparing against outdated local state — we check
    ///   whether the token we have now already differs from the one that
    ///   failed, and if so, just return the current one instead of
    ///   refreshing twice.
    public func handleUnauthorized(staleAccessToken: String) async throws -> String {
        if let current = cachedTokens, current.accessToken != staleAccessToken {
            // Someone else already refreshed after this request was sent.
            return current.accessToken
        }
        guard let refreshToken = cachedTokens?.refreshToken else {
            throw NetworkError.unauthorized
        }
        return try await performCoalescedRefresh(currentRefreshToken: refreshToken).accessToken
    }

    // MARK: - Single-flight refresh core

    private func performCoalescedRefresh(currentRefreshToken: String) async throws -> AuthTokens {
        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<AuthTokens, Error> { [refresher] in
            try await refresher.refresh(using: currentRefreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let newTokens = try await task.value
            try save(newTokens)
            return newTokens
        } catch {
            // Refresh token itself was rejected (e.g. revoked, expired) —
            // this is unrecoverable without user interaction. Clear local
            // state and surface `.unauthorized` so the app can route to
            // a login screen via the Coordinator.
            try? clear()
            throw NetworkError.unauthorized
        }
    }
}

// Small shared JSON coding helpers kept private to this module's concerns.
extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
