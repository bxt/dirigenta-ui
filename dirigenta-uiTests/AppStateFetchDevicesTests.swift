import XCTest

@testable import dirigenta_ui

// MARK: - Mock client for fetch tests

/// Minimal DirigeraClientProtocol that returns a canned device list.
@MainActor
final class MockFetchClient: DirigeraClientProtocol {
    var devicesToReturn: [DirigeraDevice] = []
    var shouldThrow = false

    nonisolated func fetchAllDevices() async throws -> [DirigeraDevice] {
        let devs = await devicesToReturn
        let throw_ = await shouldThrow
        if throw_ { throw URLError(.badServerResponse) }
        return devs
    }

    nonisolated func setLight(id: String, isOn: Bool) async throws {}
    nonisolated func setLightLevel(id: String, lightLevel: Int) async throws {}
    nonisolated func setColor(id: String, hue: Double, saturation: Double) async throws {}
    nonisolated func setColorTemperature(id: String, colorTemperature: Int) async throws {}
    nonisolated func applyColorPreset(_ preset: LightColorPreset, to id: String) async throws {}
    nonisolated func eventStream() -> AsyncStream<DirigeraEvent> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Device fixture helpers

private func device(
    id: String,
    type: String,
    deviceType: String? = nil,
    relationId: String? = nil,
    name: String = "Device",
    switchGroup: Int? = nil
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.switchGroup = switchGroup
    return DirigeraDevice(
        id: id, type: type, deviceType: deviceType,
        relationId: relationId, attributes: attrs
    )
}

// MARK: - #7  AppState.fetchDevices classification

@MainActor
final class AppStateFetchDevicesTests: XCTestCase {

    private var state: AppState!
    private var client: MockFetchClient!

    override func setUp() {
        super.setUp()
        state = AppState.preview()
        state.devices = []
        state.deviceIdMap = [:]
        client = MockFetchClient()
    }

    // MARK: Light classification

    func testFetchDevices_classifiesLights() async {
        client.devicesToReturn = [
            device(id: "l1", type: "light"),
            device(id: "l2", type: "light"),
            device(id: "s1", type: "sensor", deviceType: "openCloseSensor"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertEqual(state.devices.lights.map(\.id).sorted(), ["l1", "l2"])
    }

    func testFetchDevices_classifiesOpenCloseSensors() async {
        client.devicesToReturn = [
            device(id: "s1", type: "sensor", deviceType: "openCloseSensor"),
            device(id: "s2", type: "sensor", deviceType: "openCloseSensor"),
            device(id: "l1", type: "light"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertEqual(state.devices.openCloseSensors.map(\.id).sorted(), ["s1", "s2"])
    }

    func testFetchDevices_doesNotClassifyOpenSensorsAsLights() async {
        client.devicesToReturn = [
            device(id: "s1", type: "sensor", deviceType: "openCloseSensor"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertTrue(state.devices.lights.isEmpty)
    }

    // MARK: Environment sensor merging

    func testFetchDevices_mergesEnvironmentSensors() async {
        // Two env sensors sharing a relationId → merged into one primary entry
        client.devicesToReturn = [
            device(id: "env-1", type: "sensor", deviceType: "environmentSensor", relationId: "rel-abc"),
            device(id: "env-2", type: "sensor", deviceType: "environmentSensor", relationId: "rel-abc"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        // Merged: one entry in envSensors, both IDs mapped to the primary
        XCTAssertEqual(state.devices.envSensors.count, 1)
        XCTAssertFalse(state.deviceIdMap.isEmpty)
    }

    func testFetchDevices_doesNotPutEnvSensorsInLightsOrSensors() async {
        client.devicesToReturn = [
            device(id: "env1", type: "sensor", deviceType: "environmentSensor"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertTrue(state.devices.lights.isEmpty)
        XCTAssertTrue(state.devices.openCloseSensors.isEmpty)
    }

    // MARK: Gateway name

    func testFetchDevices_extractsGatewayName() async {
        client.devicesToReturn = [
            device(id: "gw1", type: "gateway", name: "My Hub"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertEqual(state.gatewayName, "My Hub")
    }

    func testFetchDevices_gatewayNilWhenAbsent() async {
        state.gatewayName = "Old Name"
        client.devicesToReturn = [device(id: "l1", type: "light")]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertNil(state.gatewayName)
    }

    // MARK: Loading flag

    func testFetchDevices_setsIsLoadingAndClearsAfterSuccess() async {
        client.devicesToReturn = []
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertFalse(state.isLoadingDevices)
    }

    func testFetchDevices_clearsIsLoadingAfterError() async {
        client.shouldThrow = true
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertFalse(state.isLoadingDevices)
    }

    // MARK: Error state

    func testFetchDevices_setsDevicesError_onThrow() async {
        client.shouldThrow = true
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertNotNil(state.devicesError)
    }

    func testFetchDevices_clearsDevicesError_onSuccess() async {
        state.devicesError = "Old error"
        client.devicesToReturn = []
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertNil(state.devicesError)
    }

    // MARK: Generic switch merging

    func testFetchDevices_mergesGenericSwitchesByRelationId() async {
        client.devicesToReturn = [
            device(id: "sw-1", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 1),
            device(id: "sw-2", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 2),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertEqual(state.devices.others.count, 1)
    }

    func testFetchDevices_mergedSwitch_collectsSwitchGroups() async {
        client.devicesToReturn = [
            device(id: "sw-1", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 1),
            device(id: "sw-2", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 2),
        ]
        await state.fetchDevices(ip: "x", client: client)
        let groups = state.devices.others.first?.attributes.switchGroups ?? []
        XCTAssertEqual(groups.sorted(), [1, 2])
    }

    func testFetchDevices_doesNotPutGenericSwitchesInLightsOrSensors() async {
        client.devicesToReturn = [
            device(id: "sw-1", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 1),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertTrue(state.devices.lights.isEmpty)
        XCTAssertTrue(state.devices.openCloseSensors.isEmpty)
        XCTAssertTrue(state.devices.envSensors.isEmpty)
    }

    // MARK: Mixed bag

    func testFetchDevices_classifiesAllTypesSimultaneously() async {
        client.devicesToReturn = [
            device(id: "l1", type: "light"),
            device(id: "s1", type: "sensor", deviceType: "openCloseSensor"),
            device(id: "env1", type: "sensor", deviceType: "environmentSensor"),
            device(id: "gw1", type: "gateway", name: "Hub"),
            device(id: "sw-1", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 1),
            device(id: "sw-2", type: "controller", deviceType: "genericSwitch",
                   relationId: "rel-sw", switchGroup: 2),
            device(id: "other1", type: "blinds"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertEqual(state.devices.lights.count, 1)
        XCTAssertEqual(state.devices.openCloseSensors.count, 1)
        XCTAssertEqual(state.devices.envSensors.count, 1)
        XCTAssertEqual(state.gatewayName, "Hub")
        // Two genericSwitch components → 1 merged entry + 1 blinds = 2 otherDevices
        XCTAssertEqual(state.devices.others.count, 2)
    }

    // MARK: Stable sort order

    func testFetchDevices_sortsDevicesByIdAscending() async {
        // Hub returns devices in arbitrary order; AppState must surface them
        // in id-ascending order so views render deterministically.
        client.devicesToReturn = [
            device(id: "z3", type: "light"),
            device(id: "a1", type: "light"),
            device(id: "m2", type: "sensor", deviceType: "openCloseSensor"),
        ]
        await state.fetchDevices(ip: "x", client: client)
        XCTAssertEqual(state.devices.map(\.id), ["a1", "m2", "z3"])
    }

    // MARK: Demo hub end-to-end
    //
    // Most tests above use tight ad-hoc fixtures so each classification edge
    // case is unambiguous. This one runs against the real `DemoDirigeraClient`
    // — what users see when they pick "Add Demo Hub" — to make sure the demo
    // fixture stays compatible with the live classification path. If the
    // demo hub stops producing the device shape AppState expects, this test
    // catches it before users do.

    func testFetchDevices_demoHub_classifiesEveryFamily() async {
        let demoClient = DemoDirigeraClient()
        await state.fetchDevices(ip: "demo", client: demoClient)
        XCTAssertGreaterThanOrEqual(state.devices.lights.count, 6)
        XCTAssertEqual(state.devices.openCloseSensors.count, 2)
        XCTAssertGreaterThanOrEqual(state.devices.envSensors.count, 1)
        XCTAssertEqual(state.gatewayName, "Demo Hub")
        XCTAssertTrue(state.devices.lights.contains { $0.isReachable == false })
    }

    // MARK: Auto-upgrade default displayName from gatewayName

    func testFetchDevices_upgradesDefaultDisplayName_fromGateway() async {
        let hub = Hub.real(
            displayName: Hub.defaultRealDisplayName,
            accessToken: "tok"
        )
        state.hubs = [hub]
        state.selectedHubID = hub.id

        client.devicesToReturn = [
            device(id: "gw1", type: "gateway", name: "Living Room Hub")
        ]
        await state.fetchDevices(ip: "1.2.3.4", client: client)

        XCTAssertEqual(state.selectedHub?.displayName, "Living Room Hub")
    }

    func testFetchDevices_doesNotOverwriteCustomDisplayName() async {
        let hub = Hub.real(displayName: "My Cottage", accessToken: "tok")
        state.hubs = [hub]
        state.selectedHubID = hub.id

        client.devicesToReturn = [
            device(id: "gw1", type: "gateway", name: "DIRIGERA Hub 1")
        ]
        await state.fetchDevices(ip: "1.2.3.4", client: client)

        XCTAssertEqual(
            state.selectedHub?.displayName,
            "My Cottage",
            "fetchDevices must not overwrite a name the user has already customized"
        )
    }

    func testFetchDevices_doesNotUpgradeDisplayName_whenGatewayMissing() async {
        let hub = Hub.real(
            displayName: Hub.defaultRealDisplayName,
            accessToken: "tok"
        )
        state.hubs = [hub]
        state.selectedHubID = hub.id

        client.devicesToReturn = [device(id: "l1", type: "light")]
        await state.fetchDevices(ip: "1.2.3.4", client: client)

        XCTAssertEqual(
            state.selectedHub?.displayName,
            Hub.defaultRealDisplayName
        )
    }
}
