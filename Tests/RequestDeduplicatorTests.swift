//
//  RequestDeduplicatorTests.swift
//  NetworkLayerTests
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("RequestDeduplicator")
struct RequestDeduplicatorTests {

    @Test("Concurrent identical requests share a single execution")
    func concurrentRequestsAreDeduplicated() async throws {
        let deduplicator = RequestDeduplicator()
        let executionCounter = ExecutionCounter()

        // Fire 10 concurrent "requests" for the SAME key using a task
        // group so they genuinely overlap rather than running sequentially.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await deduplicator.execute(key: "same-key") {
                        await executionCounter.increment()
                        // Simulate network latency so all 10 callers are
                        // guaranteed to arrive while the first is in-flight.
                        try await Task.sleep(nanoseconds: 30_000_000)
                        return 42
                    }
                }
            }
            for try await value in group {
                #expect(value == 42)
            }
        }

        let count = await executionCounter.count
        #expect(count == 1, "Only one underlying execution should have occurred for 10 concurrent callers")
    }

    @Test("Sequential requests after completion each execute independently")
    func sequentialRequestsAfterCompletionAreNotDeduplicated() async throws {
        let deduplicator = RequestDeduplicator()
        let executionCounter = ExecutionCounter()

        _ = try await deduplicator.execute(key: "seq-key") {
            await executionCounter.increment(); return 1
        }
        _ = try await deduplicator.execute(key: "seq-key") {
            await executionCounter.increment(); return 2
        }

        let count = await executionCounter.count
        #expect(count == 2, "Requests that don't overlap in time should each run")
    }

    @Test("Different keys never share execution")
    func differentKeysAreIndependent() async throws {
        let deduplicator = RequestDeduplicator()
        async let a = deduplicator.execute(key: "A") { 1 }
        async let b = deduplicator.execute(key: "B") { 2 }
        let (resultA, resultB) = try await (a, b)
        #expect(resultA == 1)
        #expect(resultB == 2)
    }

    @Test("A failure in the shared execution propagates to all waiters")
    func failurePropagatesToAllWaiters() async throws {
        let deduplicator = RequestDeduplicator()
        var caughtErrors = 0

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try await deduplicator.execute(key: "fail-key") {
                        try await Task.sleep(nanoseconds: 10_000_000)
                        throw NetworkError.transport(description: "boom")
                    } as Int
                }
            }
            while let next = await group.nextResult() {
                if case .failure = next { caughtErrors += 1 }
            }
        }

        #expect(caughtErrors == 5, "Every waiter should observe the shared failure")
    }
}

/// A tiny actor purely to count executions in a data-race-free way across
/// concurrent tasks — using a plain `var` here would be a data race.
actor ExecutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
