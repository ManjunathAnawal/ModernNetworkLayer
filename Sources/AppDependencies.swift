//
//  AppDependencies.swift
//  NetworkLayer
//
//  The composition root: the ONE place in the app that knows how to
//  construct concrete implementations and wire them together. Every other
//  file in this package depends only on protocols
//  (`NetworkClient`, `UserRepository`, `TokenRefreshing`, ...), never on
//  this file — that's what makes every layer independently unit-testable.
//
//  TRADE-OFF NOTE — manual DI container vs. a DI framework (e.g.
//  Swinject, Factory):
//  We wire dependencies by hand in a single `AppDependencies` struct
//  rather than adopting a DI framework. For an app of small-to-medium
//  size, manual wiring is fully type-checked at compile time (a typo'd
//  dependency name is a compiler error, not a runtime crash from a
//  framework's string/type registry lookup), has zero third-party
//  dependency risk, and is trivial for new team members to read
//  top-to-bottom. Reach for a DI framework instead once the object graph
//  gets large enough that manual wiring becomes unwieldy (dozens of
//  interdependent services, multiple build flavors needing different
//  graphs, or a need for scoped/per-screen lifetimes that a hand-rolled
//  struct doesn't express cleanly) — Swinject/Factory earn their keep at
//  that scale by making assembly declarative and reducing boilerplate.
//
import Foundation

/// Example concrete `TokenRefreshing` — calls the real refresh endpoint.
/// `requiresAuth` is false here specifically to avoid infinite recursion
/// (refreshing a token must never itself require a valid access token).
struct AuthRefreshEndpoint: Endpoint {
    let refreshToken: String
    var baseURL: URL { URL(string: "https://api.example.com")! }
    var path: String { "/v1/auth/refresh" }
    var method: HTTPMethod { .post }
    var requiresAuth: Bool { false }
    var cachePolicy: CachePolicy { .none }
    var isRetryable: Bool { false } // Don't auto-retry auth mutations.
    var body: Data? { try? JSONEncoder().encode(["refresh_token": refreshToken]) }
}

struct RefreshResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
}

/// Bridges the generic `NetworkClient` into the specific `TokenRefreshing`
/// contract `TokenStore` needs. Kept as its own tiny type (rather than
/// making `APIClient` itself implement `TokenRefreshing`) to avoid a
/// circular dependency: `APIClient` needs a `RequestAuthenticating`
/// (backed by `TokenStore`) to attach headers, while `TokenStore` needs
/// something that can make network calls to refresh — if `APIClient`
/// implemented `TokenRefreshing` directly, constructing the object graph
/// would require each half to already exist before the other, which is
/// impossible. Using a plain `URLSession`-backed refresher here (bypassing
/// `APIClient`'s auth-attachment step, which is correct since
/// `requiresAuth` is false anyway) breaks the cycle cleanly.
struct URLSessionTokenRefresher: TokenRefreshing {
    let session: URLSession
    let decoder: JSONDecoder

    func refresh(using refreshToken: String) async throws -> AuthTokens {
        let endpoint = AuthRefreshEndpoint(refreshToken: refreshToken)
        let request = try endpoint.urlRequest()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NetworkError.unauthorized
        }
        let dto = try decoder.decode(RefreshResponseDTO.self, from: data)
        return AuthTokens(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresAt: Date().addingTimeInterval(dto.expiresIn)
        )
    }
}

@MainActor
public final class AppDependencies {
    public let apiClient: NetworkClient
    public let tokenStore: TokenStore
    public let userRepository: UserRepository

    public init() {
        let decoder = JSONDecoder.robust
        let session = URLSession(configuration: .default)

        let refresher = URLSessionTokenRefresher(session: session, decoder: decoder)
        let keychain = KeychainHelper()
        let tokenStore = TokenStore(keychain: keychain, refresher: refresher)
        self.tokenStore = tokenStore

        let monitor = NetworkMonitor()
        Task { await monitor.start() }

        let client = APIClient(
            session: session,
            monitor: monitor,
            cache: ResponseCache(),
            deduplicator: RequestDeduplicator(),
            authenticator: TokenAuthenticator(tokenStore: tokenStore),
            retryPolicy: .default,
            decoder: decoder
        )
        self.apiClient = client
        self.userRepository = UserRepositoryImpl(client: client)

        Task { await tokenStore.bootstrap() }
    }
}
