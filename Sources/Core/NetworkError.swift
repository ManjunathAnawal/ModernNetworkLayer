//
//  NetworkError.swift
//  NetworkLayer
//
//  A single, exhaustive error type for the networking stack.
//
//  TRADE-OFF NOTE — one big enum vs. per-layer errors:
//  We deliberately use ONE `NetworkError` enum shared by the transport,
//  caching, and auth layers instead of separate `TransportError`,
//  `CacheError`, `AuthError` types that get wrapped/rethrown at each
//  boundary. Reasoning:
//    - Call sites (ViewModels) almost always want to `switch` once to
//      decide UI state (offline banner vs. retry button vs. logout).
//      A single flat enum makes that switch exhaustive and simple.
//    - Wrapping errors in nested types tends to produce deeply nested
//      `case .transport(.cache(.expired))` pyramids that are painful to
//      pattern-match against in tests and in SwiftUI `.alert` bindings.
//  When you SHOULD split it up: if this were a multi-module SDK shipped
//  to third parties, per-module error namespaces avoid one module's
//  changes forcing a major version bump on every consumer. For an app's
//  internal networking layer, the unified enum wins on ergonomics.
//
import Foundation

public enum NetworkError: Error, Equatable, Sendable {
    /// Raised by the network interceptor *before* a request is even
    /// attempted, when `NWPathMonitor` reports no connectivity and no
    /// usable cached response exists for the request.
    case offline

    /// The server returned a non-2xx status code. We keep the raw body
    /// (as Data) so callers can attempt to decode a server-defined error
    /// payload (e.g. `{"message": "..."}`) without us guessing its shape.
    case http(statusCode: Int, data: Data?, retryAfter: TimeInterval?)

    /// Decoding the response body into the requested `Decodable` type failed.
    /// We carry a description rather than the underlying `DecodingError`
    /// itself so that `NetworkError` can remain `Equatable` (DecodingError
    /// is not Equatable), which is important for asserting on errors in tests.
    case decoding(description: String)

    /// The request could not be encoded (e.g. bad body encoding).
    case encoding(description: String)

    /// Authentication failed permanently — refresh token was itself
    /// rejected. This is the signal the app should use to force a logout.
    case unauthorized

    /// The request was retried the maximum number of times and still failed.
    case retryExhausted(underlying: NetworkErrorBox)

    /// The URLSession task was cancelled — usually because the caller's
    /// `Task` was cancelled (e.g. the user navigated away). Distinguishing
    /// this from a "real" failure lets ViewModels ignore it silently
    /// instead of showing an error toast for a screen no one is looking at.
    case cancelled

    /// Catch-all for URLSession-level transport failures (DNS, TLS, etc.)
    /// that are not modeled explicitly above.
    case transport(description: String)

    /// The request builder produced an invalid `URLRequest` (e.g. bad URL).
    case invalidRequest(description: String)

    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.offline, .offline), (.unauthorized, .unauthorized), (.cancelled, .cancelled):
            return true
        case let (.http(l1, l2, l3), .http(r1, r2, r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case let (.decoding(l), .decoding(r)):
            return l == r
        case let (.encoding(l), .encoding(r)):
            return l == r
        case let (.transport(l), .transport(r)):
            return l == r
        case let (.invalidRequest(l), .invalidRequest(r)):
            return l == r
        case let (.retryExhausted(l), .retryExhausted(r)):
            return l == r
        default:
            return false
        }
    }
}

/// A boxed, `Equatable`-friendly wrapper around an arbitrary `Error` so it
/// can be embedded inside `NetworkError` (which must stay `Equatable` for
/// testability) without losing the original failure for logging purposes.
public struct NetworkErrorBox: Error, Equatable, @unchecked Sendable {
    public let underlying: Error
    public init(_ underlying: Error) { self.underlying = underlying }

    // We can't meaningfully compare arbitrary `Error`s, so equality is
    // based on their string description. This is sufficient for unit
    // tests that assert "retry exhausted, wrapping *a* timeout error"
    // rather than a specific instance.
    public static func == (lhs: NetworkErrorBox, rhs: NetworkErrorBox) -> Bool {
        String(describing: lhs.underlying) == String(describing: rhs.underlying)
    }
}
