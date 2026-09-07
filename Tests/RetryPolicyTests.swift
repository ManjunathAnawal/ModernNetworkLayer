//
//  RetryPolicyTests.swift
//  NetworkLayerTests
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("RetryPolicy")
struct RetryPolicyTests {

    @Test("Retryable status codes are retried within attempt budget")
    func retryableStatusWithinBudget() {
        let policy = RetryPolicy(maxAttempts: 3)
        #expect(policy.shouldRetry(attempt: 1, statusCode: 503, isTransportError: false))
        #expect(policy.shouldRetry(attempt: 2, statusCode: 429, isTransportError: false))
        #expect(!policy.shouldRetry(attempt: 3, statusCode: 503, isTransportError: false), "Should stop at maxAttempts")
    }

    @Test("Non-retryable status codes are never retried")
    func nonRetryableStatusIsNeverRetried() {
        let policy = RetryPolicy(maxAttempts: 5)
        #expect(!policy.shouldRetry(attempt: 1, statusCode: 400, isTransportError: false))
        #expect(!policy.shouldRetry(attempt: 1, statusCode: 404, isTransportError: false))
        #expect(!policy.shouldRetry(attempt: 1, statusCode: 401, isTransportError: false))
    }

    @Test("Transport-level errors are retried regardless of status code")
    func transportErrorsAreRetried() {
        let policy = RetryPolicy(maxAttempts: 3)
        #expect(policy.shouldRetry(attempt: 1, statusCode: nil, isTransportError: true))
    }

    @Test("Exponential backoff grows with attempt number and stays within maxDelay")
    func backoffGrowsAndCaps() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1.0, maxDelay: 10.0)
        // Full jitter means delay is randomized between 0 and the
        // exponential cap, so we assert on the UPPER BOUND behavior
        // (the theoretical max for that attempt) rather than exact values.
        for attempt in 1...6 {
            let delay = policy.delay(forAttempt: attempt)
            let theoreticalMax = min(1.0 * pow(2.0, Double(attempt - 1)), 10.0)
            #expect(delay >= 0)
            #expect(delay <= theoreticalMax)
        }
    }

    @Test("Server Retry-After header overrides computed backoff")
    func retryAfterOverridesBackoff() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0, maxDelay: 100.0)
        let delay = policy.delay(forAttempt: 5, serverRetryAfter: 42)
        #expect(delay == 42)
    }

    @Test("Retry-After is clamped to maxDelay to protect against misbehaving servers")
    func retryAfterIsClamped() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0, maxDelay: 10.0)
        let delay = policy.delay(forAttempt: 1, serverRetryAfter: 3600)
        #expect(delay == 10.0)
    }

    @Test("Retry-After parses integer-seconds form")
    func parsesIntegerSecondsRetryAfter() {
        let parsed = RetryPolicy.parseRetryAfter("120")
        #expect(parsed == 120)
    }

    @Test("Retry-After parses HTTP-date form")
    func parsesHTTPDateRetryAfter() {
        let future = Date().addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let headerValue = formatter.string(from: future)

        let parsed = RetryPolicy.parseRetryAfter(headerValue)
        #expect(parsed != nil)
        // Allow a couple seconds of test-execution slack.
        #expect(abs((parsed ?? 0) - 60) < 3)
    }

    @Test("Missing or malformed Retry-After returns nil")
    func malformedRetryAfterReturnsNil() {
        #expect(RetryPolicy.parseRetryAfter(nil) == nil)
        #expect(RetryPolicy.parseRetryAfter("not-a-number-or-date") == nil)
    }
}
