//
//  TokenStoreTests.swift
//  NetworkLayerTests
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("TokenStore")
struct TokenStoreTests {

    private func makeStore(refresher: MockTokenRefresher, expiringSoon: Bool = false) async throws -> TokenStore {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, refresher: refresher)
        let expiry = expiringSoon
            ? Date().addingTimeInterval(5)   // within the 30s "expiring soon" window
            : Date().addingTimeInterval(3600)
        try await store.save(AuthTokens(accessToken: "initial-access", refreshToken: "initial-refresh", expiresAt: expiry))
        return store
    }

    @Test("A valid, non-expiring token is returned without calling the refresher")
    func validTokenSkipsRefresh() async throws {
        let refresher = MockTokenRefresher()
        let store = try await makeStore(refresher: refresher, expiringSoon: false)

        let token = try await store.validAccessToken()
        #expect(token == "initial-access")
        let calls = await refresher.callCount
        #expect(calls == 0)
    }

    @Test("An expiring-soon token triggers exactly one refresh even with many concurrent callers")
    func concurrentExpiringTokenRequestsCoalesceIntoOneRefresh() async throws {
        let refresher = MockTokenRefresher()
        let store = try await makeStore(refresher: refresher, expiringSoon: true)

        // 20 "requests" all discover the token is expiring soon at once.
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.validAccessToken() }
            }
            var results: Set<String> = []
            for try await token in group { results.insert(token) }
            // All callers must receive the SAME new token.
            #expect(results == ["new-access-1"])
        }

        let calls = await refresher.callCount
        #expect(calls == 1, "Refresh storm prevention failed: expected exactly 1 refresh call")
    }

    @Test("401 recovery triggers refresh and retried requests get the new token")
    func unauthorizedRecoveryRefreshesAndReturnsNewToken() async throws {
        let refresher = MockTokenRefresher()
        let store = try await makeStore(refresher: refresher, expiringSoon: false)

        let newToken = try await store.handleUnauthorized(staleAccessToken: "initial-access")
        #expect(newToken == "new-access-1")
        let calls = await refresher.callCount
        #expect(calls == 1)
    }

    @Test("A caller reporting a stale 401 after another refresh already happened does not double-refresh")
    func staleUnauthorizedDoesNotDoubleRefresh() async throws {
        let refresher = MockTokenRefresher()
        let store = try await makeStore(refresher: refresher, expiringSoon: false)

        // Simulate: request A and request B were both sent with
        // "initial-access". Request A's 401 comes back first and triggers
        // a refresh. By the time request B's 401 comes back, the token
        // has already changed underneath it.
        _ = try await store.handleUnauthorized(staleAccessToken: "initial-access")
        let secondCallResult = try await store.handleUnauthorized(staleAccessToken: "initial-access")

        #expect(secondCallResult == "new-access-1", "Second caller should get the already-refreshed token")
        let calls = await refresher.callCount
        #expect(calls == 1, "Should not have triggered a second refresh")
    }

    @Test("A permanently rejected refresh token surfaces .unauthorized and clears local session")
    func failedRefreshClearsSessionAndSurfacesUnauthorized() async throws {
        let refresher = MockTokenRefresher()
        await refresher.setShouldFail(true)
        let store = try await makeStore(refresher: refresher, expiringSoon: true)

        do {
            _ = try await store.validAccessToken()
            Issue.record("Expected .unauthorized to be thrown")
        } catch let error as NetworkError {
            #expect(error == .unauthorized)
        }

        // Subsequent calls should also fail (no cached token remains) —
        // proves `clear()` actually ran.
        do {
            _ = try await store.validAccessToken()
            Issue.record("Expected .unauthorized to be thrown on second call")
        } catch let error as NetworkError {
            #expect(error == .unauthorized)
        }
    }
}

private extension MockTokenRefresher {
    func setShouldFail(_ value: Bool) { self.shouldFail = value }
}
