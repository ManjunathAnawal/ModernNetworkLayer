//
//  TestDoubles.swift
//  NetworkLayerTests
//
import Foundation
@testable import NetworkLayer

/// Simple endpoint used across tests to avoid depending on the User
/// feature's endpoint enum for generic client behavior tests.
struct TestEndpoint: Endpoint {
    var baseURL: URL = URL(string: "https://api.example.com")!
    var path: String = "/v1/ping"
    var method: HTTPMethod = .get
    var requiresAuth: Bool = false
    var cachePolicy: CachePolicy = .none
    var isRetryable: Bool = true
}

struct TestModel: Codable, Equatable {
    let message: String
}

/// A `TokenRefreshing` double whose behavior (success/failure, latency,
/// and call count) is fully controllable from tests, used to prove the
/// single-flight refresh coalescing behavior of `TokenStore`.
actor MockTokenRefresher: TokenRefreshing {
    private(set) var callCount = 0
    var shouldFail = false
    /// Simulated network latency so tests can create genuine concurrent
    /// overlap between multiple callers awaiting the same refresh.
    var artificialDelayNanoseconds: UInt64 = 50_000_000 // 50ms

    func refresh(using refreshToken: String) async throws -> AuthTokens {
        callCount += 1
        try await Task.sleep(nanoseconds: artificialDelayNanoseconds)
        if shouldFail {
            throw NetworkError.unauthorized
        }
        return AuthTokens(
            accessToken: "new-access-\(callCount)",
            refreshToken: "new-refresh-\(callCount)",
            expiresAt: Date().addingTimeInterval(3600)
        )
    }
}

/// Minimal `NetworkClient` double for Repository-layer unit tests, so
/// those tests never touch URLSession/MockURLProtocol at all.
final class MockNetworkClient: NetworkClient, @unchecked Sendable {
    var resultProvider: ((any Endpoint) throws -> Any)?

    func request<T: Decodable>(_ endpoint: any Endpoint, as type: T.Type) async throws -> T {
        guard let resultProvider, let value = try resultProvider(endpoint) as? T else {
            throw NetworkError.decoding(description: "MockNetworkClient misconfigured")
        }
        return value
    }

    func requestVoid(_ endpoint: any Endpoint) async throws {
        _ = try resultProvider?(endpoint)
    }
}
