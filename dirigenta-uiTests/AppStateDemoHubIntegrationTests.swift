import XCTest

@testable import dirigenta_ui

// MARK: - End-to-end smoke tests for the demo hub fixture
//
// These exercise the full chain `addDemoHub → switchHub → makeClient
// (DemoDirigeraClient) → fetchDevices` so the demo hub stays usable as the
// "QA / first-launch demo" surface. Logic-only tests that need precise
// fixtures (window-notifier trajectories, env-sensor edge cases, generic
// switch merging, etc.) keep their tight ad-hoc devices in the dedicated
// test files — using the demo hub there would lose precision.

@MainActor
final class AppStateDemoHubIntegrationTests: XCTestCase {

    private var state: AppState!

    override func setUp() {
        super.setUp()
        state = AppState(
            credentialStore: InMemoryCredentialStore(),
            mdns: MDNSResolver(networkingEnabled: false)
        )
    }

    private func selectDemoHub() {
        state.hubs = [Hub.demo()]
        state.selectedHubID = Hub.demoID
    }

    // MARK: - addDemoHub

    func testAddDemoHub_appendsAndSelectsDemoHub() {
        XCTAssertTrue(state.hubs.isEmpty)
        state.addDemoHub()
        XCTAssertEqual(state.hubs.count, 1)
        XCTAssertEqual(state.selectedHubID, Hub.demoID)
        XCTAssertEqual(state.selectedHub?.kind, .demo)
    }

    func testAddDemoHub_isIdempotent() {
        state.addDemoHub()
        state.addDemoHub()
        XCTAssertEqual(
            state.hubs.filter { $0.kind == .demo }.count,
            1,
            "calling addDemoHub twice must not produce duplicate demo entries"
        )
    }

    func testAddDemoHub_alongsideRealHub_keepsRealHub() {
        let real = Hub.real(displayName: "Home", accessToken: "tok")
        state.hubs = [real]
        state.selectedHubID = real.id

        state.addDemoHub()

        XCTAssertEqual(state.hubs.count, 2)
        XCTAssertTrue(state.hubs.contains { $0.kind == .real })
        XCTAssertEqual(
            state.selectedHubID,
            Hub.demoID,
            "addDemoHub switches to the demo hub even when a real hub is already selected"
        )
    }

    // MARK: - hasDemoHub

    func testHasDemoHub_falseWhenEmpty() {
        XCTAssertFalse(state.hasDemoHub)
    }

    func testHasDemoHub_falseWithOnlyRealHubs() {
        state.hubs = [Hub.real(displayName: "Home", accessToken: "tok")]
        XCTAssertFalse(state.hasDemoHub)
    }

    func testHasDemoHub_trueAfterAddingDemoHub() {
        state.addDemoHub()
        XCTAssertTrue(state.hasDemoHub)
    }

    // MARK: - removeHub on demo

    func testRemoveDemoHub_clearsSelection_whenItWasOnlyHub() {
        state.addDemoHub()
        state.removeHub(Hub.demoID)
        XCTAssertTrue(state.hubs.isEmpty)
        XCTAssertNil(state.selectedHubID)
    }

    // MARK: - currentHubIP / makeClient routing

    func testCurrentHubIP_returnsDemoSentinel_forDemoHub() {
        selectDemoHub()
        XCTAssertEqual(state.currentHubIP, "demo")
    }

    func testMakeClient_returnsDemoClient_forDemoHub() {
        selectDemoHub()
        let client = state.makeClient(ip: "demo")
        XCTAssertNotNil(client)
        XCTAssertTrue(
            client is DemoDirigeraClient,
            "demo hub must produce a DemoDirigeraClient regardless of IP"
        )
    }

    func testMakeClient_demoHub_cachesAcrossCalls() {
        selectDemoHub()
        let c1 = state.makeClient(ip: "demo")
        let c2 = state.makeClient(ip: "demo")
        XCTAssertTrue(
            c1 === c2,
            "demo client must be cached so its in-memory state survives across calls"
        )
    }

    // MARK: - fetchDevices populates the expected device shape

    func testFetchDevices_demoHub_classifiesEachDeviceFamily() async throws {
        selectDemoHub()
        let client = try XCTUnwrap(state.makeClient(ip: "demo"))
        await state.fetchDevices(ip: "demo", client: client)

        XCTAssertGreaterThanOrEqual(
            state.devices.lights.count,
            6,
            "demo set should expose at least 6 lights so room views look populated"
        )
        XCTAssertEqual(
            state.devices.openCloseSensors.count,
            2,
            "demo set should expose 2 open/close sensors"
        )
        XCTAssertGreaterThanOrEqual(
            state.devices.envSensors.count,
            1,
            "demo set should include at least one environment sensor"
        )
        XCTAssertEqual(state.gatewayName, "Demo Hub")
    }

    func testFetchDevices_demoHub_includesUnreachableLight() async throws {
        selectDemoHub()
        let client = try XCTUnwrap(state.makeClient(ip: "demo"))
        await state.fetchDevices(ip: "demo", client: client)

        XCTAssertTrue(
            state.devices.lights.contains { $0.isReachable == false },
            "demo set must include an unreachable light so the offline warning UI is exercised"
        )
    }

    // MARK: - Switching back to a real hub evicts the demo client

    func testSwitchFromDemoToReal_evictsCachedClient() {
        let real = Hub.real(displayName: "Home", accessToken: "tok")
        state.hubs = [Hub.demo(), real]
        state.selectedHubID = Hub.demoID

        let demoClient = state.makeClient(ip: "demo")
        XCTAssertTrue(demoClient is DemoDirigeraClient)

        state.switchHub(to: real.id)

        // After switching, asking for a client for the new hub must produce a
        // fresh non-demo instance — the cached DemoDirigeraClient is evicted.
        let realClient = state.makeClient(ip: "10.0.0.1")
        XCTAssertNotNil(realClient)
        XCTAssertFalse(
            realClient is DemoDirigeraClient,
            "switching from demo to real must evict the cache and produce a real client"
        )
    }
}
