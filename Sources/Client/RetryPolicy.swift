//
//  RetryPolicy.swift
//  NetworkLayer
//
//  Encapsulates "should we retry, and if so, after how long" decisions,
//  separate from `APIClient`'s transport concerns, so the backoff math
//  can be unit-tested deterministically without any networking involved.
//
//  TRADE-OFF NOTE — jittered exponential backoff vs. fixed-delay retry:
//  A fixed delay (e.g. "always wait 1s") is simple but causes a "thundering
//  herd": if a backend hiccups and drops requests from 10,000 clients at
//  once, all 10,000 retry at exactly t+1s, re-creating the same overload.
//  Exponential backoff spreads retries out over time as attempts increase;
//  adding *jitter* (randomization) additionally decorrelates clients that
//  failed at the same instant. This is the standard AWS/Google SRE-
//  recommended approach ("exponential backoff with full jitter").
//  When a fixed delay is fine: low-traffic internal tools or single-user
//  local-network services where herd effects on a shared backend aren't a
//  concern.
//
import Foundation

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    /// Which HTTP status codes are considered transient/retryable.
    /// 429 (rate limited) and 5xx (server errors) are classic candidates;
    /// 408 (request timeout) as well. 4xx client errors other than 429 are
    /// deliberately excluded — retrying a 400 Bad Request will just fail
    /// identically forever and wastes the retry budget.
    public let retryableStatusCodes: Set<Int>

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 8.0,
        retryableStatusCodes: Set<Int> = Set([408, 429]).union(500...599)
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatusCodes = retryableStatusCodes
    }

    public static let `default` = RetryPolicy()
    /// A policy for tests that need retries to resolve near-instantly.
    public static let fastForTesting = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.05)

    public func shouldRetry(attempt: Int, statusCode: Int?, isTransportError: Bool) -> Bool {
        guard attempt < maxAttempts else { return false }
        if isTransportError { return true } // e.g. timed out / no connection mid-flight
        guard let statusCode else { return false }
        return retryableStatusCodes.contains(statusCode)
    }

    /// Computes the delay before the *next* attempt (1-indexed: delay
    /// before attempt #2 uses `attempt == 1`).
    ///
    /// - Parameter serverRetryAfter: if the server sent a `Retry-After`
    ///   header, we honor it verbatim (clamped to `maxDelay` to avoid a
    ///   misbehaving server telling us to wait an hour) rather than
    ///   computing our own backoff — the server has more information
    ///   about its own recovery time than we do.
    public func delay(forAttempt attempt: Int, serverRetryAfter: TimeInterval? = nil) -> TimeInterval {
        if let serverRetryAfter {
            return min(serverRetryAfter, maxDelay)
        }

        // Exponential: baseDelay * 2^(attempt-1), capped at maxDelay.
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))
        let capped = min(exponential, maxDelay)

        // "Full jitter" per AWS's backoff literature: pick a uniformly
        // random delay between 0 and the capped exponential value, rather
        // than adding a small random offset on top of it. This gives the
        // best spread of retry times among competing clients.
        return Double.random(in: 0...capped)
    }

    /// Parses the standard `Retry-After` header, which per RFC 7231 may be
    /// EITHER an integer number of seconds OR an HTTP-date.
    public static func parseRetryAfter(_ headerValue: String?) -> TimeInterval? {
        guard let headerValue else { return nil }
        if let seconds = TimeInterval(headerValue) { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: headerValue) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
