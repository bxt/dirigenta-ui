import Network
import XCTest

@testable import dirigenta_ui

@MainActor
final class MDNSDiscoveryTests: XCTestCase {

    // MARK: - IP address formatting (pure)

    func testIPv4StringRepresentation() {
        let addr = IPv4Address("192.168.1.100")!
        XCTAssertEqual(
            MDNSResolver.ipString(from: .ipv4(addr)),
            "192.168.1.100"
        )
    }

    func testIPv6StringRepresentation() {
        let addr = IPv6Address("fe80::1")!
        XCTAssertEqual(MDNSResolver.ipString(from: .ipv6(addr)), "[fe80::1]")
    }

    func testLoopbackIPv4() {
        let addr = IPv4Address("127.0.0.1")!
        XCTAssertEqual(MDNSResolver.ipString(from: .ipv4(addr)), "127.0.0.1")
    }

    func testHostnamePassthrough() {
        XCTAssertEqual(
            MDNSResolver.ipString(from: .name("dirigera.local", nil)),
            "dirigera.local"
        )
    }

    // MARK: - State machine (no real networking)

    // Tests below use `networkingEnabled: false` so we exercise the start/stop
    // contract without instantiating NWBrowser / NWPathMonitor — those require
    // entitlements and a stable code-signing identity that an unsigned CI test
    // binary doesn't have.

    func testStartSetsIsResolving() {
        let resolver = MDNSResolver(networkingEnabled: false)
        XCTAssertFalse(resolver.isResolving)
        resolver.start()
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    func testStartIsIdempotent() {
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        resolver.start()  // second call should be a no-op
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    func testStopClearsState() {
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        resolver.stop()
        XCTAssertFalse(resolver.isResolving)
    }

    func testRetryResetsAndRestarts() {
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        resolver.stop()
        XCTAssertFalse(resolver.isResolving)
        resolver.retry()
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    // MARK: - ip(forHub:) lookup (pure)

    func testIpForHub_returnsDemoSentinelForDemoHub() {
        let resolver = MDNSResolver(networkingEnabled: false)
        XCTAssertEqual(resolver.ip(forHub: Hub.demo()), "demo")
    }

    func testIpForHub_returnsNil_whenNoDiscoveredHubs() {
        let resolver = MDNSResolver(networkingEnabled: false)
        let hub = Hub.real(displayName: "Home", accessToken: "tok")
        XCTAssertNil(resolver.ip(forHub: hub))
    }

    func testIpForHub_returnsMostRecentDiscovered_whenNoLastKnownIP() {
        let resolver = MDNSResolver(networkingEnabled: false)
        let now = Date()
        resolver.discoveredHubs = [
            DiscoveredHub(ip: "10.0.0.1", serviceName: "older", lastSeenAt: now.addingTimeInterval(-60)),
            DiscoveredHub(ip: "10.0.0.2", serviceName: "newer", lastSeenAt: now),
        ]
        let hub = Hub.real(displayName: "Home", accessToken: "tok")
        XCTAssertEqual(resolver.ip(forHub: hub), "10.0.0.2")
    }

    func testIpForHub_prefersLastKnownIP_whenStillAdvertised() {
        let resolver = MDNSResolver(networkingEnabled: false)
        let now = Date()
        resolver.discoveredHubs = [
            DiscoveredHub(ip: "10.0.0.1", serviceName: "older", lastSeenAt: now.addingTimeInterval(-60)),
            DiscoveredHub(ip: "10.0.0.2", serviceName: "newer", lastSeenAt: now),
        ]
        var hub = Hub.real(displayName: "Home", accessToken: "tok")
        hub.lastKnownIP = "10.0.0.1"
        XCTAssertEqual(resolver.ip(forHub: hub), "10.0.0.1")
    }

    func testIpForHub_ignoresLastKnownIP_whenNoLongerAdvertised() {
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.discoveredHubs = [
            DiscoveredHub(ip: "10.0.0.2", serviceName: "newer", lastSeenAt: Date())
        ]
        var hub = Hub.real(displayName: "Home", accessToken: "tok")
        hub.lastKnownIP = "10.0.0.99"  // stale
        XCTAssertEqual(resolver.ip(forHub: hub), "10.0.0.2")
    }

    // MARK: - Integration: requires a Dirigera hub on the local network.
    // Skipped on CI; run manually with the hub powered on.
    func testDiscoverHubOnLocalNetwork() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipped on CI: requires a Dirigera hub on the local network and Network framework entitlements"
        )

        let resolver = MDNSResolver()
        resolver.start()
        defer { resolver.stop() }

        for _ in 0..<50 {
            if !resolver.discoveredHubs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        let hub = try XCTUnwrap(
            resolver.discoveredHubs.first,
            "No Dirigera hub discovered within 10 seconds — ensure the hub is powered on and on the local network"
        )
        print("[Test] Discovered Dirigera hub at: \(hub.ip)")
    }
}
