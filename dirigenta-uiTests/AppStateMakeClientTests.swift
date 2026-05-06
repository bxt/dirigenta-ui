import XCTest

@testable import dirigenta_ui

// MARK: - #11  AppState.makeClient cache behaviour

@MainActor
final class AppStateMakeClientTests: XCTestCase {

    private var state: AppState!

    override func setUp() {
        super.setUp()
        // Inject in-memory credential store and a network-disabled MDNS so
        // mutating hub state doesn't write to the real Keychain and starting
        // the resolver doesn't touch NWBrowser.
        state = AppState(
            credentialStore: InMemoryCredentialStore(),
            mdns: MDNSResolver(networkingEnabled: false)
        )
        let hub = Hub.real(displayName: "Test Hub", accessToken: "test-token")
        state.hubs = [hub]
        state.selectedHubID = hub.id
    }

    // MARK: No-hub guard

    func testMakeClient_returnsNil_whenNoHubSelected() {
        state.hubs = []
        state.selectedHubID = nil
        XCTAssertNil(state.makeClient(ip: "10.0.0.1"))
    }

    func testMakeClient_returnsNil_whenSelectedHubHasNoToken() {
        var hub = state.hubs[0]
        hub.accessToken = nil
        state.hubs[0] = hub
        XCTAssertNil(state.makeClient(ip: "10.0.0.1"))
    }

    // MARK: Identity / caching

    func testMakeClient_sameIP_returnsSameInstance() {
        let c1 = state.makeClient(ip: "192.168.1.10")
        let c2 = state.makeClient(ip: "192.168.1.10")
        XCTAssertNotNil(c1)
        XCTAssertTrue(
            c1 === c2,
            "makeClient must return the cached instance for the same IP"
        )
    }

    func testMakeClient_differentIP_returnsDifferentInstance() {
        let c1 = state.makeClient(ip: "192.168.1.10")
        let c2 = state.makeClient(ip: "192.168.1.20")
        XCTAssertFalse(
            c1 === c2,
            "makeClient must allocate a new client when the IP changes"
        )
    }

    func testMakeClient_sameIPThreeTimes_alwaysSameInstance() {
        let c1 = state.makeClient(ip: "10.0.0.1")
        let c2 = state.makeClient(ip: "10.0.0.1")
        let c3 = state.makeClient(ip: "10.0.0.1")
        XCTAssertTrue(c1 === c2)
        XCTAssertTrue(c2 === c3)
    }

    func testMakeClient_afterIPChange_newCallWithOldIPCreatesNewInstance() {
        let c1 = state.makeClient(ip: "10.0.0.1")
        _ = state.makeClient(ip: "10.0.0.2")  // evicts c1
        let c3 = state.makeClient(ip: "10.0.0.1")  // must be fresh, not c1
        XCTAssertFalse(
            c1 === c3,
            "after eviction, same IP must produce a new client (old URLSession is gone)"
        )
    }

    // MARK: Hub identity is part of the cache key

    func testMakeClient_switchingHub_evictsCache() {
        let c1 = state.makeClient(ip: "10.0.0.1")
        let other = Hub.real(
            displayName: "Other Hub",
            accessToken: "other-token"
        )
        state.hubs.append(other)
        state.switchHub(to: other.id)
        let c2 = state.makeClient(ip: "10.0.0.1")
        XCTAssertFalse(
            c1 === c2,
            "switching hub must evict the cache and produce a new client"
        )
    }
}
