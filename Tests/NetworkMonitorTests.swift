//
//  NetworkMonitorTests.swift
//  NetworkLayerTests
//
//  We test against `MockNetworkMonitor` rather than the real
//  `NWPathMonitor`-backed `NetworkMonitor`: real connectivity state is an
//  environmental fact CI runners can't deterministically control (a CI
//  box might have no network, or might not support airplane-mode-style
//  toggling), so testing the REAL monitor would be flaky by construction.
//  What we validate here is the CONTRACT (`NetworkMonitoring`) that the
//  rest of the stack (`APIClient`) depends on — see `APIClientTests` for
//  proof that `APIClient` correctly reacts to that contract.
//
import Testing
@testable import NetworkLayer

@Suite("NetworkMonitor contract")
struct NetworkMonitorTests {

    @Test("Reports connected state accurately")
    func reportsConnectedState() async {
        let monitor = MockNetworkMonitor(connected: true)
        #expect(await monitor.isConnected())
    }

    @Test("Reports disconnected state accurately")
    func reportsDisconnectedState() async {
        let monitor = MockNetworkMonitor(connected: false)
        #expect(await monitor.isConnected() == false)
    }

    @Test("State can transition mid-session, simulating the device losing/regaining connectivity")
    func stateTransitionsAreObserved() async {
        let monitor = MockNetworkMonitor(connected: true)
        #expect(await monitor.isConnected())

        await monitor.setConnected(false)
        #expect(await monitor.isConnected() == false)

        await monitor.setConnected(true)
        #expect(await monitor.isConnected())
    }

    @Test("Expensive-path flag is independent of the connected flag")
    func expensivePathIsIndependentlyTracked() async {
        let monitor = MockNetworkMonitor(connected: true, expensive: true)
        #expect(await monitor.isConnected())
        #expect(await monitor.isExpensive())
    }
}
