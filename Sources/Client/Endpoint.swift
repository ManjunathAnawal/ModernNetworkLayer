//
//  Endpoint.swift
//  NetworkLayer
//
//  A declarative description of a single API request. Keeping this as
//  data (rather than each Repository building `URLRequest`s ad hoc)
//  centralizes cache-policy, auth, and retry configuration per-endpoint
//  and makes both production code and tests trivially able to construct
//  requests without duplicating URL-building logic.
//
import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

public protocol Endpoint: Sendable {
    var baseURL: URL { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String] { get }
    var queryItems: [URLQueryItem] { get }
    var body: Data? { get }

    /// Whether this endpoint needs an Authorization header at all. Login/
    /// refresh/public-content endpoints should return `false` to avoid a
    /// chicken-and-egg dependency on having a token to fetch a token.
    var requiresAuth: Bool { get }

    /// How responses to this endpoint should be cached. GET requests to
    /// slow-changing data should use `.staticData`; mutating requests
    /// must use `.none`.
    var cachePolicy: CachePolicy { get }

    /// Per-endpoint timeout override. Defaults to the client's global
    /// timeout when nil — lets e.g. a file upload endpoint specify a much
    /// longer timeout than a simple GET.
    var timeout: TimeInterval? { get }

    /// Whether a failed attempt at this endpoint is safe to retry
    /// automatically. GET is idempotent by definition; POST/PATCH/DELETE
    /// default to `false` unless the endpoint is known-idempotent
    /// server-side (e.g. it's backed by an idempotency key).
    var isRetryable: Bool { get }
}

// Sensible defaults so most conforming endpoints only need to specify
// the handful of properties that actually differ from the norm.
public extension Endpoint {
    var headers: [String: String] { [:] }
    var queryItems: [URLQueryItem] { [] }
    var body: Data? { nil }
    var requiresAuth: Bool { true }
    var cachePolicy: CachePolicy { method == .get ? .liveData(maxAge: 30) : .none }
    var timeout: TimeInterval? { nil }
    var isRetryable: Bool { method == .get }

    func urlRequest() throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else {
            throw NetworkError.invalidRequest(description: "Could not build URL for path \(path)")
        }

        var request = URLRequest(url: url, cachePolicy: cachePolicy.urlRequestCachePolicy)
        request.httpMethod = method.rawValue
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if body != nil && request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    /// Stable identity for the deduplicator & cache-freshness bookkeeping:
    /// method + absolute URL (including query) + a hash of the body. Two
    /// requests are "the same" for dedup purposes iff all three match.
    func deduplicationKey() throws -> String {
        let request = try urlRequest()
        let urlString = request.url?.absoluteString ?? path
        let bodyHash = body.map { String($0.hashValue) } ?? "nobody"
        return "\(method.rawValue)|\(urlString)|\(bodyHash)"
    }
}
