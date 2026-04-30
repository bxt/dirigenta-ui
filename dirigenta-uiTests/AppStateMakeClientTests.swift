import XCTest

@testable import dirigenta_ui

// MARK: - #11  AppState.makeClient cache behaviour

@MainActor
final class AppStateMakeClientTests: XCTestCase {

    private var state: AppState!

    override func setUp() {
        super.setUp()
        // Use preview() because it provides a non-empty accessToken.
        // NOTE: Since isPreview is false in the test runner, accessToken's didSet
        // calls saveCredentials() and writes to Keychain. We clean up in tearDown.
        state = AppState.preview()
    }

    override func tearDown() {
        // Clean up any Keychain entries written by accessToken's didSet (saveCredentials).
        try? KeychainService.delete("dirigeraHub")
        super.tearDown()
    }

    // MARK: Identity / caching

    func testMakeClient_sameIP_returnsSameInstance() {
        let c1 = state.makeClient(ip: "192.168.1.10")
        let c2 = state.makeClient(ip: "192.168.1.10")
        XCTAssertTrue(c1 === c2, "makeClient must return the cached instance for the same IP")
    }

    func testMakeClient_differentIP_returnsDifferentInstance() {
        let c1 = state.makeClient(ip: "192.168.1.10")
        let c2 = state.makeClient(ip: "192.168.1.20")
        XCTAssertFalse(c1 === c2, "makeClient must allocate a new client when the IP changes")
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
        XCTAssertFalse(c1 === c3,
            "after eviction, same IP must produce a new client (old URLSession is gone)")
    }

    // MARK: Token is baked in at creation time

    func testMakeClient_usesCurrentAccessToken() {
        // Two different tokens → two different client instances even for same IP
        state.accessToken = "token-A"
        let c1 = state.makeClient(ip: "10.0.0.1")

        // Evict the cache so we get a fresh client with the new token
        state.accessToken = "token-B"
        // accessToken's didSet evicts the cache, so next call creates a new client
        let c2 = state.makeClient(ip: "10.0.0.1")
        XCTAssertFalse(c1 === c2,
            "changing the access token must evict the cache and produce a new client")
    }
}
