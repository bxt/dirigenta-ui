import XCTest

@testable import dirigenta_ui

@MainActor
final class MDNSResolverStopGuardTests: XCTestCase {

    // All resolvers below use networkingEnabled: false so the tests don't
    // touch NWBrowser / NWPathMonitor — see MDNSDiscoveryTests for the why.

    func testStopThenStart_allowsSecondStart() {
        // After stop(), hasStarted is reset so start() runs again
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
        XCTAssertFalse(resolver.isResolving)
        resolver.start()  // must not be a no-op
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    func testStop_withoutStart_doesNotCrash() {
        // stop() on a fresh resolver must be harmless
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.stop()  // should not crash or assert
        XCTAssertFalse(resolver.isResolving)
    }

    func testStop_isIdempotent() {
        // Calling stop() twice in a row must be harmless
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        resolver.stop()
        resolver.stop()  // second stop — should not crash
        XCTAssertFalse(resolver.isResolving)
    }
}