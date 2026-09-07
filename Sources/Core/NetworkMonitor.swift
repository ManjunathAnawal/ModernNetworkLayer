//
//  NetworkMonitor.swift
//  NetworkLayer
//
//  Proactively tracks device connectivity using NWPathMonitor so the
//  APIClient can short-circuit requests (throw `.offline` or fall back to
//  cache) BEFORE paying the cost of a doomed URLSession round trip.
//
//  THREAD SAFETY:
//  NWPathMonitor delivers updates on an arbitrary internal dispatch queue
//  that we specify (`monitorQueue`), not necessarily the main thread and
//  not necessarily serialized with caller access. Rather than guard
//  mutable state with locks, we model the monitor as an `actor`. Actors
//  serialize all access to their mutable state automatically, which is a
//  much safer default than hand-rolled locking for a component that both
//  receives async callback updates and is queried concurrently from many
//  in-flight requests.
//
//  We bridge the callback-based NWPathMonitor API into the actor using a
//  `Task` that hops onto the actor's executor to apply updates — this
//  is the standard "callback -> actor" bridge pattern in Swift Concurrency.
//
import Foundation
import Network

public protocol NetworkMonitoring: Sendable {
    /// Instantaneous connectivity snapshot. Safe to call from any context;
    /// actor isolation guarantees a consistent read.
    func isConnected() async -> Bool

    /// True if the current path is "expensive" (e.g. cellular / hotspot).
    /// Useful for callers that want to avoid large downloads on metered
    /// connections even though the network is technically up.
    func isExpensive() async -> Bool

    /// Starts monitoring. Safe to call multiple times (idempotent).
    func start() async

    /// Stops monitoring — call from app teardown / tests to avoid leaking
    /// the underlying dispatch queue.
    func stop() async
}

public actor NetworkMonitor: NetworkMonitoring {
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.app.networklayer.pathmonitor")
    private var currentPath: NWPath?
    private var isStarted = false

    public init(requiredInterfaceType: NWInterface.InterfaceType? = nil) {
        if let requiredInterfaceType {
            self.monitor = NWPathMonitor(requiredInterfaceType: requiredInterfaceType)
        } else {
            self.monitor = NWPathMonitor()
        }
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // NWPathMonitor's handler fires on `monitorQueue`. We cannot mutate
        // actor state directly from that closure (it's not actor-isolated),
        // so we hop back onto the actor via a detached Task. This is the
        // canonical bridge for legacy callback APIs into actor isolation.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.updatePath(path) }
        }
        monitor.start(queue: monitorQueue)
    }

    public func stop() {
        monitor.cancel()
        isStarted = false
    }

    public func isConnected() -> Bool {
        // `currentPath` defaults to nil until the first callback fires.
        // We treat "unknown" as "connected" (optimistic) rather than
        // blocking all requests at cold start before NWPathMonitor has
        // reported its first status — the first real request will simply
        // fail naturally (and quickly) if we guessed wrong.
        currentPath?.status == .satisfied || currentPath == nil
    }

    public func isExpensive() -> Bool {
        currentPath?.isExpensive ?? false
    }

    private func updatePath(_ path: NWPath) {
        self.currentPath = path
    }
}

/// A deterministic, test-only implementation that lets unit tests flip
/// connectivity synchronously without touching real system APIs — real
/// `NWPathMonitor` behavior is not controllable/deterministic in CI.
public actor MockNetworkMonitor: NetworkMonitoring {
    private var connected: Bool
    private var expensive: Bool

    public init(connected: Bool = true, expensive: Bool = false) {
        self.connected = connected
        self.expensive = expensive
    }

    public func setConnected(_ value: Bool) { connected = value }
    public func setExpensive(_ value: Bool) { expensive = value }
    public func isConnected() -> Bool { connected }
    public func isExpensive() -> Bool { expensive }
    public func start() {}
    public func stop() {}
}
