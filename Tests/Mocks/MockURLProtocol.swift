//
//  MockURLProtocol.swift
//  NetworkLayerTests
//
//  Intercepts URLSession traffic at the transport layer so `APIClient`
//  tests exercise the REAL `URLSession` machinery (real request
//  construction, real response parsing) without ever touching a real
//  network — the gold standard for testing networking code, as opposed to
//  mocking `URLSession` itself (which risks testing against an inaccurate
//  mental model of its behavior rather than the real thing).
//
import Foundation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Handler type: given the request, return (response, data, error).
    /// Static and queue-based because `URLProtocol` subclasses are
    /// instantiated internally by `URLSession` — we have no way to inject
    /// per-instance state, so a static queue of expected responses,
    /// guarded by a lock, is the standard pattern for this kind of mock.
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handlerQueue: [Handler] = []
    private static var callCount = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlerQueue.removeAll()
        callCount = 0
    }

    /// Queue one response. Multiple calls let a single test simulate a
    /// sequence (e.g. "first call 500s, second call succeeds" for retry
    /// tests).
    static func enqueue(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlerQueue.append(handler)
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.callCount += 1
        let handler = Self.handlerQueue.isEmpty ? nil : Self.handlerQueue.removeFirst()
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    /// A session configured to route all traffic through `MockURLProtocol`,
    /// for injection into `APIClient` under test.
    static var mocked: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
