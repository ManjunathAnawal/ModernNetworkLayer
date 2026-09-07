//
//  APIClient.swift
//  NetworkLayer
//
//  The orchestration point that ties together every enterprise component:
//  connectivity check -> cache lookup -> deduplication -> auth ->
//  transport -> retry -> 401 recovery -> caching the result -> decoding.
//
//  ARCHITECTURE: this type deliberately does NOT know about domain models
//  (`User`, etc.) — it only knows `Endpoint` and `Decodable`. Domain
//  knowledge lives in the Repository layer above it. This keeps
//  `APIClient` reusable across every feature module in the app and
//  testable with a handful of endpoints rather than the entire API surface.
//
import Foundation

/// The narrow protocol Repositories depend on. Defining this as a
/// protocol (rather than depending on `APIClient` concretely) is what
/// makes Repository unit tests possible without any real networking —
/// see `MockNetworkClient` in the test target.
public protocol NetworkClient: Sendable {
    func request<T: Decodable>(_ endpoint: Endpoint, as type: T.Type) async throws -> T
    /// For endpoints whose response body is irrelevant (e.g. 204 No Content).
    func requestVoid(_ endpoint: Endpoint) async throws
}

public final class APIClient: NetworkClient {
    private let session: URLSession
    private let monitor: NetworkMonitoring
    private let cache: ResponseCache
    private let deduplicator: RequestDeduplicator
    private let authenticator: RequestAuthenticating?
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder

    /// Off-main decoding: URLSession delegate callbacks already land on a
    /// background queue/thread by default (we don't set a custom delegate
    /// queue tied to main), but the crucial guarantee we need is that
    /// `JSONDecoder.decode` — which is synchronous, CPU-bound work that
    /// can genuinely take multiple milliseconds for large payloads — never
    /// runs on the cooperative thread pool's main-actor-adjacent context
    /// in a way that blocks UI. Because `request(_:as:)` is an `async`
    /// function NOT annotated `@MainActor`, and we never hop to
    /// `MainActor` before calling `decoder.decode`, Swift Concurrency runs
    /// this on a background thread from the global cooperative pool
    /// automatically. Callers (ViewModels) that need the *result* on the
    /// main actor perform that hop themselves, after decoding is done —
    /// see `UserProfileViewModel` for the pattern.
    public init(
        session: URLSession = .shared,
        monitor: NetworkMonitoring,
        cache: ResponseCache,
        deduplicator: RequestDeduplicator = RequestDeduplicator(),
        authenticator: RequestAuthenticating? = nil,
        retryPolicy: RetryPolicy = .default,
        decoder: JSONDecoder = .robust
    ) {
        self.session = session
        self.monitor = monitor
        self.cache = cache
        self.deduplicator = deduplicator
        self.authenticator = authenticator
        self.retryPolicy = retryPolicy
        self.decoder = decoder
    }

    public func requestVoid(_ endpoint: Endpoint) async throws {
        _ = try await performRequest(endpoint)
    }

    public func request<T: Decodable>(_ endpoint: Endpoint, as type: T.Type) async throws -> T {
        let data = try await performRequest(endpoint)
        do {
            // See init() doc comment: this runs off the main actor already.
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(description: String(describing: error))
        }
    }

    // MARK: - Orchestration core

    private func performRequest(_ endpoint: Endpoint) async throws -> Data {
        let dedupKey = try endpoint.deduplicationKey()

        // Deduplication wraps the ENTIRE pipeline (cache check through
        // network) so that concurrent identical requests share not just
        // the network call but also the cache-freshness decision — this
        // avoids a narrow race where two callers both see "no fresh cache"
        // and both proceed to the network independently before either has
        // had a chance to populate the cache.
        return try await deduplicator.execute(key: dedupKey) { [self] in
            try await resolveWithConnectivityAndCache(endpoint)
        }
    }

    private func resolveWithConnectivityAndCache(_ endpoint: Endpoint) async throws -> Data {
        let baseRequest = try endpoint.urlRequest()

        // 1. Cache fast-path: fresh cache entry satisfies the request
        //    without touching the network OR requiring connectivity at all.
        if let fresh = cache.freshResponse(for: baseRequest, policy: endpoint.cachePolicy) {
            return fresh.data
        }

        // 2. Proactive connectivity gate — this is the "intercepts requests
        //    before execution" requirement. We check BEFORE constructing
        //    the auth headers or touching URLSession at all, so an offline
        //    device fails fast (near-instantly) instead of waiting out a
        //    30s socket timeout.
        guard await monitor.isConnected() else {
            // Fall back to ANY cached response (even stale) rather than
            // failing outright — stale data usually beats a blank screen.
            if let stale = cache.anyResponse(for: baseRequest) {
                return stale.data
            }
            throw NetworkError.offline
        }

        // 3. Attach auth if required.
        var authorizedRequest = baseRequest
        var sentAccessToken: String?
        if endpoint.requiresAuth, let authenticator {
            authorizedRequest = try await authenticator.authenticate(baseRequest)
            sentAccessToken = authorizedRequest.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "")
        }

        // 4. Execute with retry + 401 recovery.
        let (data, response) = try await executeWithRetry(
            request: authorizedRequest,
            endpoint: endpoint,
            sentAccessToken: sentAccessToken,
            attempt: 1
        )

        // 5. Store into cache for next time, only for cacheable, successful GETs.
        if endpoint.cachePolicy != .none, let httpResponse = response as? HTTPURLResponse,
           (200...299).contains(httpResponse.statusCode) {
            let cached = CachedURLResponse(response: httpResponse, data: data)
            cache.store(response: cached, for: baseRequest)
        }

        return data
    }

    /// Recursive retry loop. Recursion (rather than a `while` loop) makes
    /// the "attempt N of M" state explicit in the call stack, which reads
    /// cleanly given how many distinct exit/retry conditions there are
    /// (success, retryable-status, 401, transport error, exhausted).
    private func executeWithRetry(
        request: URLRequest,
        endpoint: Endpoint,
        sentAccessToken: String?,
        attempt: Int
    ) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (data, response) // Non-HTTP response (rare); pass through.
            }

            // --- 401 handling: attempt exactly one token refresh + retry
            //     cycle per request, regardless of the endpoint's general
            //     retry policy (auth recovery is orthogonal to transient-
            //     error retries and shouldn't consume the retry budget or
            //     be blocked by `isRetryable == false` mutating endpoints —
            //     a PATCH that failed auth should still get one honest
            //     retry with a fresh token before we give up). We guard
            //     against infinite loops with the `sentAccessToken != nil`
            //     check: we only try this once per request via the
            //     `hasAttemptedRefresh` flag captured in the recursive call.
            if httpResponse.statusCode == 401,
               endpoint.requiresAuth,
               let authenticator,
               let sentAccessToken {
                let retriedRequest = try await authenticator.handleUnauthorized(
                    originalRequest: request,
                    sentAccessToken: sentAccessToken
                )
                // Re-run once with the new token. We pass `sentAccessToken:
                // nil` so a SECOND 401 (refresh succeeded but new token is
                // *still* rejected — a genuinely broken account/session)
                // falls through to being surfaced as a normal HTTP error
                // rather than looping refresh attempts forever.
                return try await executeWithRetry(
                    request: retriedRequest,
                    endpoint: endpoint,
                    sentAccessToken: nil,
                    attempt: attempt
                )
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let retryAfter = RetryPolicy.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))

                if endpoint.isRetryable,
                   retryPolicy.shouldRetry(attempt: attempt, statusCode: httpResponse.statusCode, isTransportError: false) {
                    let delay = retryPolicy.delay(forAttempt: attempt, serverRetryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return try await executeWithRetry(
                        request: request, endpoint: endpoint,
                        sentAccessToken: sentAccessToken, attempt: attempt + 1
                    )
                }

                throw NetworkError.http(statusCode: httpResponse.statusCode, data: data, retryAfter: retryAfter)
            }

            return (data, response)

        } catch let error as NetworkError {
            throw error // Already classified (e.g. the .http thrown above); don't re-wrap.

        } catch is CancellationError {
            throw NetworkError.cancelled

        } catch {
            // URLSession transport-level failure (timeout, DNS, TLS, dropped
            // connection mid-request, etc).
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }

            if endpoint.isRetryable,
               retryPolicy.shouldRetry(attempt: attempt, statusCode: nil, isTransportError: true) {
                let delay = retryPolicy.delay(forAttempt: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await executeWithRetry(
                    request: request, endpoint: endpoint,
                    sentAccessToken: sentAccessToken, attempt: attempt + 1
                )
            }

            if attempt >= retryPolicy.maxAttempts {
                throw NetworkError.retryExhausted(underlying: NetworkErrorBox(error))
            }
            throw NetworkError.transport(description: nsError.localizedDescription)
        }
    }
}
