//
//  CachePolicy.swift
//  NetworkLayer
//
//  Defines a small, expressive cache policy model layered on top of
//  Foundation's `URLCache`, so each `Endpoint` can declare how it wants to
//  be cached without every call site fiddling with `URLRequest.CachePolicy`
//  and `Cache-Control` semantics directly.
//
//  TRADE-OFF NOTE — URLCache vs. a custom disk/memory cache:
//  We build on top of `URLCache` (backed by a shared `URLSession`
//  configuration) rather than rolling a bespoke cache (e.g. a
//  Core Data / SQLite-backed store). Reasoning:
//    - URLCache already implements correct HTTP semantics (ETags,
//      Last-Modified, Cache-Control, Vary) when the server cooperates,
//      which is exactly what "static data" endpoints benefit from.
//    - It's free disk + memory tiering with eviction, no extra code.
//  When you SHOULD roll your own: if you need to cache *decoded domain
//  models* (not raw HTTP responses), need cache entries queryable by
//  arbitrary keys unrelated to URLs, or need cross-endpoint invalidation
//  ("clear everything about user 123"). In that case, layer a
//  repository-level cache (see `UserRepositoryImpl`) on top of this one —
//  which is exactly what we do below for the "live data" tier.
//
import Foundation

/// Describes how a given endpoint's response should be cached.
public enum CachePolicy: Sendable, Equatable {
    /// Never cache. Use for mutating requests (POST/PUT/DELETE) and for
    /// highly sensitive data that should never touch disk.
    case none

    /// Cache aggressively for data that rarely changes (e.g. app config,
    /// country lists, static content). `maxAge` is enforced by us on top
    /// of whatever the server sends, so misconfigured backends can't
    /// accidentally serve stale-forever data.
    case staticData(maxAge: TimeInterval)

    /// Prefer the network, but allow a *very* short-lived cache purely to
    /// collapse near-simultaneous identical requests (e.g. a feed that's
    /// refreshed on pull-to-refresh AND on view-appear within the same
    /// second). Distinct from single-flight deduplication (see
    /// `RequestDeduplicator`) which only collapses truly *concurrent*
    /// requests — this also serves rapid *sequential* repeats.
    case liveData(maxAge: TimeInterval)

    var maxAge: TimeInterval {
        switch self {
        case .none: return 0
        case .staticData(let maxAge), .liveData(let maxAge): return maxAge
        }
    }

    /// Maps our policy onto the closest `URLRequest.CachePolicy` primitive.
    /// We always use `.returnCacheDataElseLoad` for cacheable tiers and let
    /// our own `maxAge` check (applied in `APIClient`) decide freshness,
    /// rather than relying solely on the server's `Cache-Control` header —
    /// this protects us from backends that forget to set caching headers.
    var urlRequestCachePolicy: URLRequest.CachePolicy {
        switch self {
        case .none:
            return .reloadIgnoringLocalCacheData
        case .staticData, .liveData:
            return .returnCacheDataElseLoad
        }
    }
}

/// Thin wrapper around `URLCache` that adds our own age-based freshness
/// check on top of the standard cached response, and exposes an explicit
/// "store" API so the `APIClient` can control exactly when responses are
/// persisted (only for successful, cacheable requests).
public final class ResponseCache: @unchecked Sendable {
    private let urlCache: URLCache

    // Cached responses don't carry "the moment we stored them" out of the
    // box in a way that's convenient to inspect, so we stamp our own
    // metadata dictionary (URL -> storedAt) guarded by a lock. This is a
    // small amount of auxiliary state, so a simple NSLock is appropriate
    // here rather than promoting this whole type to an actor (which would
    // force all callers — including synchronous `URLProtocol`-adjacent
    // code — to become async).
    private let lock = NSLock()
    private var storedAt: [URL: Date] = [:]

    public init(memoryCapacity: Int = 20 * 1024 * 1024,   // 20 MB
                diskCapacity: Int = 100 * 1024 * 1024) {   // 100 MB
        // `directory: nil` lets the system choose the standard per-app
        // cache directory rather than us hand-rolling a path — avoids
        // subtle bugs around App Group containers / sandbox changes.
        self.urlCache = URLCache(memoryCapacity: memoryCapacity,
                                  diskCapacity: diskCapacity,
                                  directory: nil)
    }

    /// Testing/DI hook to inject a specific URLCache (e.g. an in-memory-only
    /// cache for unit tests to avoid touching disk).
    public init(urlCache: URLCache) {
        self.urlCache = urlCache
    }

    public var sessionConfigurationCache: URLCache { urlCache }

    public func store(response: CachedURLResponse, for request: URLRequest) {
        urlCache.storeCachedResponse(response, for: request)
        if let url = request.url {
            lock.lock()
            storedAt[url] = Date()
            lock.unlock()
        }
    }

    /// Returns a cached response only if it exists AND is within the
    /// policy's `maxAge`. This is the extra freshness gate mentioned above.
    public func freshResponse(for request: URLRequest, policy: CachePolicy) -> CachedURLResponse? {
        guard policy != .none,
              let cached = urlCache.cachedResponse(for: request),
              let url = request.url else { return nil }

        lock.lock()
        let storedDate = storedAt[url]
        lock.unlock()

        // If we don't have our own timestamp (e.g. app relaunch cleared
        // the in-memory dictionary but disk cache persisted), fall back to
        // trusting URLCache — better to serve slightly-stale-but-present
        // data than to silently discard a perfectly usable cache entry.
        guard let storedDate else { return cached }

        let age = Date().timeIntervalSince(storedDate)
        return age <= policy.maxAge ? cached : nil
    }

    /// Returns any cached response regardless of freshness — used as the
    /// last-resort fallback when the device is offline (stale data is
    /// better than no data for most UX).
    public func anyResponse(for request: URLRequest) -> CachedURLResponse? {
        urlCache.cachedResponse(for: request)
    }

    public func removeAll() {
        urlCache.removeAllCachedResponses()
        lock.lock()
        storedAt.removeAll()
        lock.unlock()
    }
}
