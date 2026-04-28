import XCTest
import Network
@testable import dirigenta_ui

@MainActor
final class MDNSDiscoveryTests: XCTestCase {

    // MARK: - Unit tests for IP address formatting (no network required)

    func testIPv4StringRepresentation() {
        let addr = IPv4Address("192.168.1.100")!
        XCTAssertEqual(MDNSResolver.ipString(from: .ipv4(addr)), "192.168.1.100")
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
        XCTAssertEqual(MDNSResolver.ipString(from: .name("dirigera.local", nil)), "dirigera.local")
    }

    func testStartSetsIsResolving() {
        let resolver = MDNSResolver()
        XCTAssertFalse(resolver.isResolving)
        resolver.start()
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    func testStartIsIdempotent() {
        let resolver = MDNSResolver()
        resolver.start()
        resolver.start() // second call should be a no-op
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    func testStopClearsState() {
        let resolver = MDNSResolver()
        resolver.start()
        resolver.stop()
        XCTAssertFalse(resolver.isResolving)
    }

    // MARK: - Integration test: requires a Dirigera hub on the local network.
    // Run this test manually to verify mDNS discovery works end-to-end.
    // It will fail in CI or environments without a hub — that is expected.
    func testDiscoverHubOnLocalNetwork() async throws {
        let resolver = MDNSResolver()
        resolver.start()
        defer { resolver.stop() }

        for _ in 0..<50 {
            if resolver.currentIPAddress != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        let ip = try XCTUnwrap(
            resolver.currentIPAddress,
            "No Dirigera hub discovered within 10 seconds — ensure the hub is powered on and on the local network"
        )
        print("[Test] Discovered Dirigera hub at: \(ip)")
    }
}
