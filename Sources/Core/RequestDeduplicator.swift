//
//  RequestDeduplicator.swift
//  NetworkLayer
//
//  Prevents redundant concurrent network calls: if three parts of the UI
//  ask for `GET /users/42` within the same moment (e.g. three widgets on
//  one screen), only ONE URLSession task is actually started; all three
//  callers await the same result.
//
//  THREAD SAFETY / DESIGN:
//  Implemented as an `actor` keyed by a caller-supplied `String` (typically
//  the request's method + URL + body hash). The key insight for making
//  this work with `async/await` is storing an *in-flight Task* (not just a
//  "please wait" flag) in the dictionary. Additional callers that find an
//  existing Task simply `await` its `.value` — Swift's `Task` already
//  memoizes its result and is safe to await from multiple places
//  concurrently, so we get de-duplication "for free" once we've stored it.
//
//  MEMORY MANAGEMENT:
//  We remove the entry from `inFlight` as soon as the task completes
//  (success OR failure) via a `defer`-like continuation inside the task
//  body itself, so the dictionary never accumulates stale entries and
//  a *new* request for the same key after completion correctly triggers a
//  fresh network call rather than replaying an old result forever.
//
import Foundation

public actor RequestDeduplicator {
    /// Type-erased so a single dictionary can hold in-flight tasks for
    /// endpoints with different `Decodable` result types. We erase to
    /// `Any` and force-cast back to the expected type at the call site;
    /// this is safe because the *key* already encodes the endpoint
    /// (method+URL+body), so a key collision across different response
    /// types would indicate a hash-construction bug elsewhere, not a
    /// runtime data race.
    private var inFlight: [String: Task<Any, Error>] = [:]

    public init() {}

    /// Runs `operation` for `key`, or, if an identical request is already
    /// in flight, awaits that existing task's result instead of starting
    /// a new one.
    ///
    /// - Parameters:
    ///   - key: A stable identity for "the same request" (see
    ///     `Endpoint.deduplicationKey` for how this is constructed).
    ///   - operation: The actual network operation. Only invoked if no
    ///     identical request is currently in flight.
    public func execute<T: Sendable>(
        key: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        // Case 1: a matching request is already running — piggyback on it.
        if let existing = inFlight[key] {
            let value = try await existing.value
            // Force-cast is safe: see type-erasure note above.
            guard let typed = value as? T else {
                throw NetworkError.decoding(description: "Deduplicator type mismatch for key \(key)")
            }
            return typed
        }

        // Case 2: no in-flight request — create one and publish it
        // *before* awaiting, so any caller that arrives while we're
        // suspended on the network call below will see it in the dict.
        let task = Task<Any, Error> {
            try await operation()
        }
        inFlight[key] = task

        // Ensure cleanup happens regardless of success/failure/cancellation.
        // Because this whole function body runs on the actor's executor,
        // this mutation of `inFlight` is automatically data-race-free.
        defer { inFlight[key] = nil }

        let result = try await task.value
        guard let typed = result as? T else {
            throw NetworkError.decoding(description: "Deduplicator type mismatch for key \(key)")
        }
        return typed
    }

    /// Testing hook — number of currently in-flight unique requests.
    public var activeCount: Int { inFlight.count }
}
