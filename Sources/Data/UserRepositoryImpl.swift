//
//  UserRepositoryImpl.swift
//  NetworkLayer
//
//  Concrete implementation of `UserRepository`, living in the `Data`
//  layer. Depends on the `NetworkClient` PROTOCOL (not `APIClient`
//  concretely) — this is the Dependency Inversion that lets
//  `UserRepositoryTests` inject `MockNetworkClient` and never touch
//  URLSession.
//
import Foundation

/// Concrete `Endpoint` values for the User feature. Grouping them in an
/// enum keeps every URL/method/cache-policy decision for this feature in
/// one reviewable place instead of scattered across call sites.
enum UserEndpoint: Endpoint {
    case fetchUser(id: String)
    case fetchUsers(pageToken: String?)
    case updateDisplayName(userID: String, newName: String)

    var baseURL: URL { URL(string: "https://api.example.com")! }

    var path: String {
        switch self {
        case .fetchUser(let id): return "/v1/users/\(id)"
        case .fetchUsers: return "/v1/users"
        case .updateDisplayName(let id, _): return "/v1/users/\(id)"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .fetchUser, .fetchUsers: return .get
        case .updateDisplayName: return .patch
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .fetchUsers(let pageToken):
            guard let pageToken else { return [] }
            return [URLQueryItem(name: "page_token", value: pageToken)]
        default:
            return []
        }
    }

    var body: Data? {
        switch self {
        case .updateDisplayName(_, let newName):
            return try? JSONEncoder().encode(["display_name": newName])
        default:
            return nil
        }
    }

    var cachePolicy: CachePolicy {
        switch self {
        // A single user's profile changes moderately often (status,
        // display name) — short-lived "live" cache collapses rapid
        // repeat views without risking showing very stale data.
        case .fetchUser: return .liveData(maxAge: 30)
        // A user list/page is more expensive to compute server-side and
        // changes less often screen-to-screen — cache it longer.
        case .fetchUsers: return .staticData(maxAge: 300)
        // Mutating request — never cache.
        case .updateDisplayName: return .none
        }
    }

    var isRetryable: Bool {
        switch self {
        case .fetchUser, .fetchUsers: return true
        // PATCH is not automatically retryable in general (retrying a
        // failed write can double-apply it) UNLESS the backend guarantees
        // idempotency for this exact call (common via an Idempotency-Key
        // header, omitted here for brevity). Default to false — safer.
        case .updateDisplayName: return false
        }
    }
}

public final class UserRepositoryImpl: UserRepository {
    private let client: NetworkClient

    public init(client: NetworkClient) {
        self.client = client
    }

    public func fetchUser(id: String) async throws -> User {
        try await client.request(UserEndpoint.fetchUser(id: id), as: User.self)
    }

    public func fetchUsers(pageToken: String?) async throws -> UserListResponse {
        try await client.request(UserEndpoint.fetchUsers(pageToken: pageToken), as: UserListResponse.self)
    }

    public func updateDisplayName(userID: String, newName: String) async throws -> User {
        try await client.request(UserEndpoint.updateDisplayName(userID: userID, newName: newName), as: User.self)
    }
}
