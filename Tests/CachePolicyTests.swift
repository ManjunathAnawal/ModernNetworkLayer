//
//  CachePolicyTests.swift
//  NetworkLayerTests
//
//  Unit tests `ResponseCache`'s freshness logic directly, isolated from
//  `APIClient`, so a bug in age-based expiry is pinpointed here rather
//  than only surfacing as a confusing failure deep in an integration test.
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("ResponseCache")
struct CachePolicyTests {

    private func makeRequestAndResponse(url: String = "https://api.example.com/data") -> (URLRequest, CachedURLResponse) {
        let url = URL(string: url)!
        let request = URLRequest(url: url)
        let httpResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let cached = CachedURLResponse(response: httpResponse, data: Data("payload".utf8))
        return (request, cached)
    }

    @Test("A freshly-stored response within maxAge is returned")
    func freshResponseWithinMaxAgeIsReturned() {
        let cache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let (request, response) = makeRequestAndResponse()
        cache.store(response: response, for: request)

        let result = cache.freshResponse(for: request, policy: .staticData(maxAge: 60))
        #expect(result != nil)
    }

    @Test("cachePolicy .none never returns a cached response even if one exists")
    func noneCachePolicyNeverReturnsData() {
        let cache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let (request, response) = makeRequestAndResponse()
        cache.store(response: response, for: request)

        let result = cache.freshResponse(for: request, policy: .none)
        #expect(result == nil)
    }

    @Test("A response older than maxAge is not returned as fresh")
    func staleResponseIsNotReturnedAsFresh() async throws {
        let cache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let (request, response) = makeRequestAndResponse()
        cache.store(response: response, for: request)

        // maxAge of 0 combined with any elapsed wall-clock time (even a
        // few milliseconds from the two lines above) should count as stale.
        try await Task.sleep(nanoseconds: 5_000_000)
        let result = cache.freshResponse(for: request, policy: .staticData(maxAge: 0))
        #expect(result == nil)
    }

    @Test("anyResponse ignores freshness entirely and always returns what's stored, for offline fallback")
    func anyResponseIgnoresFreshness() async throws {
        let cache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let (request, response) = makeRequestAndResponse()
        cache.store(response: response, for: request)
        try await Task.sleep(nanoseconds: 5_000_000)

        // Even though this is "stale" by policy, anyResponse should still
        // surface it — this is exactly the path APIClient uses when
        // offline and no fresh entry exists.
        #expect(cache.freshResponse(for: request, policy: .staticData(maxAge: 0)) == nil)
        #expect(cache.anyResponse(for: request) != nil)
    }

    @Test("Different URLs are cached independently")
    func differentURLsAreIndependent() {
        let cache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let (requestA, responseA) = makeRequestAndResponse(url: "https://api.example.com/a")
        let (requestB, _) = makeRequestAndResponse(url: "https://api.example.com/b")
        cache.store(response: responseA, for: requestA)

        #expect(cache.freshResponse(for: requestA, policy: .staticData(maxAge: 60)) != nil)
        #expect(cache.freshResponse(for: requestB, policy: .staticData(maxAge: 60)) == nil)
    }

    @Test("removeAll clears both cached responses and freshness bookkeeping")
    func removeAllClearsCache() {
        let cache = ResponseCache(urlCache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: nil))
        let (request, response) = makeRequestAndResponse()
        cache.store(response: response, for: request)
        #expect(cache.anyResponse(for: request) != nil)

        cache.removeAll()
        #expect(cache.anyResponse(for: request) == nil)
    }
}
