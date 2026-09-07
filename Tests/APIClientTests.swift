//
//  APIClientTests.swift
//  NetworkLayerTests
//
//  These tests exercise `APIClient` end-to-end against `MockURLProtocol`,
//  which is the highest-fidelity way to test networking code without a
//  live server: real `URLSession`, real request/response marshalling,
//  fully controlled server behavior.
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("APIClient", .serialized) // .serialized: MockURLProtocol's queue is static/global state.
struct APIClientTests {

    func makeClient(
        monitor: NetworkMonitoring = MockNetworkMonitor(connected: true),
        cache: ResponseCache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil)),
        authenticator: RequestAuthenticating? = nil,
        retryPolicy: RetryPolicy = .fastForTesting
    ) -> APIClient {
        MockURLProtocol.reset()
        return APIClient(
            session: .mocked,
            monitor: monitor,
            cache: cache,
            deduplicator: RequestDeduplicator(),
            authenticator: authenticator,
            retryPolicy: retryPolicy
        )
    }

    private func jsonResponse(_ model: TestModel, statusCode: Int = 200, headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
        let data = try! JSONEncoder().encode(model)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com/v1/ping")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a }
        )!
        return (response, data)
    }

    // MARK: - Offline behavior

    @Test("Offline device with no cache throws .offline without hitting the network")
    func offlineWithNoCacheThrowsOffline() async throws {
        let client = makeClient(monitor: MockNetworkMonitor(connected: false))
        // Deliberately do NOT enqueue any MockURLProtocol response — if the
        // client incorrectly attempted a network call, the test would fail
        // with "unknown" transport error instead of the expected .offline,
        // proving the connectivity gate runs BEFORE transport.
        do {
            _ = try await client.request(TestEndpoint(), as: TestModel.self)
            Issue.record("Expected .offline to be thrown")
        } catch let error as NetworkError {
            #expect(error == .offline)
        }
        #expect(MockURLProtocol.requestCount == 0, "No network call should have been attempted while offline")
    }

    @Test("Offline device with stale cache serves the stale cache instead of failing")
    func offlineWithStaleCacheServesStaleData() async throws {
        let sharedCache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))

        // First, go online and populate the cache.
        let onlineClient = makeClient(monitor: MockNetworkMonitor(connected: true), cache: sharedCache)
        MockURLProtocol.enqueue { request in self.jsonResponse(TestModel(message: "cached-value")) }
        let first = try await onlineClient.request(TestEndpoint(cachePolicy: .staticData(maxAge: 0)), as: TestModel.self)
        #expect(first.message == "cached-value")

        // Now go offline; policy's maxAge is 0 so it's immediately "stale"
        // by our freshness check, exercising the "any response" fallback.
        let offlineClient = makeClient(monitor: MockNetworkMonitor(connected: false), cache: sharedCache)
        let second = try await offlineClient.request(TestEndpoint(cachePolicy: .staticData(maxAge: 0)), as: TestModel.self)
        #expect(second.message == "cached-value", "Stale cache should still be served when offline")
    }

    // MARK: - Caching

    @Test("A fresh cache hit is served without any network call")
    func freshCacheHitSkipsNetwork() async throws {
        let sharedCache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let client = makeClient(cache: sharedCache)

        MockURLProtocol.enqueue { _ in self.jsonResponse(TestModel(message: "first")) }
        let endpoint = TestEndpoint(cachePolicy: .staticData(maxAge: 60))
        _ = try await client.request(endpoint, as: TestModel.self)
        #expect(MockURLProtocol.requestCount == 1)

        // Second call within maxAge should hit cache, NOT enqueue/consume
        // a second mock response.
        let second = try await client.request(endpoint, as: TestModel.self)
        #expect(second.message == "first")
        #expect(MockURLProtocol.requestCount == 1, "Second request should have been served from cache")
    }

    @Test("cachePolicy .none never serves from cache even for repeat requests")
    func noCachePolicyAlwaysHitsNetwork() async throws {
        let client = makeClient()
        MockURLProtocol.enqueue { _ in self.jsonResponse(TestModel(message: "a")) }
        MockURLProtocol.enqueue { _ in self.jsonResponse(TestModel(message: "b")) }

        let endpoint = TestEndpoint(cachePolicy: .none)
        let first = try await client.request(endpoint, as: TestModel.self)
        let second = try await client.request(endpoint, as: TestModel.self)

        #expect(first.message == "a")
        #expect(second.message == "b")
        #expect(MockURLProtocol.requestCount == 2)
    }

    // MARK: - Retry with backoff

    @Test("A 503 is retried and succeeds on a subsequent attempt")
    func retriesOnServerErrorThenSucceeds() async throws {
        let client = makeClient()
        MockURLProtocol.enqueue { _ in
            (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/ping")!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.enqueue { _ in self.jsonResponse(TestModel(message: "recovered")) }

        let result = try await client.request(TestEndpoint(isRetryable: true), as: TestModel.self)
        #expect(result.message == "recovered")
        #expect(MockURLProtocol.requestCount == 2, "Should have made exactly 2 attempts")
    }

    @Test("Non-retryable endpoint fails immediately on 503 without retrying")
    func nonRetryableEndpointDoesNotRetry() async throws {
        let client = makeClient()
        MockURLProtocol.enqueue { _ in
            (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/ping")!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await client.request(TestEndpoint(isRetryable: false), as: TestModel.self)
            Issue.record("Expected an .http error to be thrown")
        } catch let error as NetworkError {
            #expect(error == .http(statusCode: 503, data: Data(), retryAfter: nil))
        }
        #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("Retries are exhausted after maxAttempts and the failure surfaces")
    func retriesAreExhausted() async throws {
        let client = makeClient(retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02))
        for _ in 0..<3 {
            MockURLProtocol.enqueue { _ in
                (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/ping")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        do {
            _ = try await client.request(TestEndpoint(isRetryable: true), as: TestModel.self)
            Issue.record("Expected exhausted retries to surface an error")
        } catch let error as NetworkError {
            if case .http(let statusCode, _, _) = error {
                #expect(statusCode == 500)
            } else {
                Issue.record("Expected .http error, got \(error)")
            }
        }
        #expect(MockURLProtocol.requestCount == 3, "Should attempt exactly maxAttempts times, no more")
    }

    @Test("Server Retry-After header is honored for the wait before retrying")
    func honorsRetryAfterHeader() async throws {
        let client = makeClient(retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 5, maxDelay: 5))
        MockURLProtocol.enqueue { _ in
            (HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/ping")!,
                statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "0"] // 0s so the test doesn't actually wait
            )!, Data())
        }
        MockURLProtocol.enqueue { _ in self.jsonResponse(TestModel(message: "ok-after-throttle")) }

        let start = Date()
        let result = try await client.request(TestEndpoint(isRetryable: true), as: TestModel.self)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.message == "ok-after-throttle")
        // Retry-After: 0 should be used INSTEAD of the 5s configured
        // backoff — if the client ignored the header, this test would
        // take >= 5 seconds.
        #expect(elapsed < 2.0, "Retry-After header should override the much larger configured backoff")
    }

    // MARK: - 401 / token refresh integration

    @Test("A 401 triggers token refresh and the retried request succeeds with the new token")
    func unauthorizedTriggersRefreshAndRetry() async throws {
        let keychain = InMemoryKeychain()
        let refresher = MockTokenRefresher()
        let tokenStore = TokenStore(keychain: keychain, refresher: refresher)
        try await tokenStore.save(AuthTokens(accessToken: "expired-token", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600)))
        let authenticator = TokenAuthenticator(tokenStore: tokenStore)

        let client = makeClient(authenticator: authenticator)

        // First attempt: server rejects the (technically-not-yet-expired
        // per our local clock, but server disagrees) token with 401.
        MockURLProtocol.enqueue { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-token")
            return (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/ping")!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        // Second attempt (after refresh): server accepts the new token.
        MockURLProtocol.enqueue { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access-1")
            return self.jsonResponse(TestModel(message: "authorized"))
        }

        let endpoint = TestEndpoint(requiresAuth: true)
        let result = try await client.request(endpoint, as: TestModel.self)

        #expect(result.message == "authorized")
        let refreshCalls = await refresher.callCount
        #expect(refreshCalls == 1)
        #expect(MockURLProtocol.requestCount == 2)
    }

    @Test("A second consecutive 401 after refresh does not loop forever")
    func doubleUnauthorizedDoesNotInfiniteLoop() async throws {
        let keychain = InMemoryKeychain()
        let refresher = MockTokenRefresher()
        let tokenStore = TokenStore(keychain: keychain, refresher: refresher)
        try await tokenStore.save(AuthTokens(accessToken: "expired-token", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600)))
        let authenticator = TokenAuthenticator(tokenStore: tokenStore)
        let client = makeClient(authenticator: authenticator)

        // BOTH attempts return 401 — simulates a genuinely broken session
        // even after refresh (e.g. account disabled server-side).
        MockURLProtocol.enqueue { _ in
            (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/ping")!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.enqueue { _ in
            (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/ping")!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await client.request(TestEndpoint(requiresAuth: true), as: TestModel.self)
            Issue.record("Expected the second 401 to surface as an .http error, not loop")
        } catch let error as NetworkError {
            if case .http(let statusCode, _, _) = error {
                #expect(statusCode == 401)
            } else {
                Issue.record("Expected .http(401), got \(error)")
            }
        }
        // Exactly 2 HTTP attempts and exactly 1 refresh call — proves no
        // infinite retry loop occurred.
        #expect(MockURLProtocol.requestCount == 2)
        let refreshCalls = await refresher.callCount
        #expect(refreshCalls == 1)
    }
}

// Convenience initializer so tests can override just the fields they care
// about without repeating every `Endpoint` requirement each time.

