import XCTest

@testable import dirigenta_ui

// MARK: - Helpers

private func makeDevice(id: String, type: String, deviceType: String? = nil) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.isOn = false
    return DirigeraDevice(id: id, type: type, deviceType: deviceType, attributes: attrs)
}

private func event(id: String, isOn: Bool? = nil, lightLevel: Int? = nil) -> DirigeraEvent {
    let isOnJSON = isOn.map { #""isOn": \#($0 ? "true" : "false")"# } ?? ""
    let levelJSON = lightLevel.map { #""lightLevel": \#($0)"# } ?? ""
    let attrsFields = [isOnJSON, levelJSON].filter { !$0.isEmpty }.joined(separator: ",")
    let json = """
        {
          "type": "deviceStateChanged",
          "data": {
            "id": "\(id)",
            "attributes": {\(attrsFields)}
          }
        }
        """
    return try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
}

private func device(id: String) -> (DirigeraDevice) -> Bool {
    { $0.id == id }
}

// MARK: - Tests

@MainActor
final class AppStateApplyEventTests: XCTestCase {

    private var state: AppState!

    override func setUp() {
        super.setUp()
        state = AppState.preview()
        // Override preview devices with controlled fixtures, in id-ascending
        // order to mirror what fetchDevices would produce.
        state.devices = [
            makeDevice(id: "env-primary", type: "sensor", deviceType: "environmentSensor"),
            makeDevice(id: "light-1", type: "light"),
            makeDevice(id: "light-2", type: "light"),
            makeDevice(id: "sensor-1", type: "sensor", deviceType: "openCloseSensor"),
        ]
        state.deviceIdMap = [:]
    }

    // MARK: Light routing

    func testApplyEvent_updatesMatchingLight() {
        state.applyEvent(event(id: "light-1", isOn: true))
        XCTAssertEqual(
            state.devices.first(where: device(id: "light-1"))?.attributes.isOn,
            true
        )
        XCTAssertEqual(
            state.devices.first(where: device(id: "light-2"))?.attributes.isOn,
            false
        )
    }

    func testApplyEvent_updatesLightLevel() {
        state.applyEvent(event(id: "light-2", lightLevel: 75))
        XCTAssertEqual(
            state.devices.first(where: device(id: "light-2"))?.attributes
                .lightLevel,
            75
        )
    }

    func testApplyEvent_doesNotTouchSensorsWhenLightMatches() {
        state.applyEvent(event(id: "light-1", isOn: true))
        XCTAssertFalse(
            state.devices.first(where: device(id: "sensor-1"))?.attributes.isOn
                ?? false
        )
    }

    // MARK: Sensor routing

    func testApplyEvent_updatesMatchingSensor() {
        let json = """
            {"type":"deviceStateChanged","data":{"id":"sensor-1","attributes":{"isOpen":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertEqual(
            state.devices.first(where: device(id: "sensor-1"))?.attributes
                .isOpen,
            true
        )
    }

    func testApplyEvent_doesNotTouchLightsWhenSensorMatches() {
        let json = """
            {"type":"deviceStateChanged","data":{"id":"sensor-1","attributes":{"isOpen":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertNil(
            state.devices.first(where: device(id: "light-1"))?.attributes.isOpen
        )
    }

    // MARK: Component-id routing via deviceIdMap

    func testApplyEvent_routesComponentIdToPrimaryEnvSensor() {
        // Map component id "env-component" → primary "env-primary"
        state.deviceIdMap = ["env-component": "env-primary"]
        let json = """
            {"type":"deviceStateChanged","data":{"id":"env-component","attributes":{"currentCO2":900.0}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertEqual(
            state.devices.first(where: device(id: "env-primary"))?.attributes
                .currentCO2,
            900.0
        )
    }

    func testApplyEvent_fallsBackToPrimaryId_whenNotInIdMap() {
        // Event id matches primary directly (no map entry needed)
        let json = """
            {"type":"deviceStateChanged","data":{"id":"env-primary","attributes":{"currentTemperature":22.5}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertEqual(
            state.devices.first(where: device(id: "env-primary"))?.attributes
                .currentTemperature,
            22.5
        )
    }

    func testApplyEvent_routesComponentIdToPrimaryGenericSwitch() {
        // Generic switches share the same component-id routing path: events
        // targeting a component get applied to the merged primary. This case
        // was unreachable before the refactor because applyEvent only walked
        // lights/sensors/envSensors.
        state.devices.append(
            makeDevice(
                id: "sw-primary", type: "controller",
                deviceType: "genericSwitch"
            )
        )
        state.deviceIdMap = ["sw-component": "sw-primary"]
        state.applyEvent(event(id: "sw-component", isOn: true))
        XCTAssertEqual(
            state.devices.first(where: device(id: "sw-primary"))?.attributes
                .isOn,
            true
        )
    }

    // MARK: Guard conditions

    func testApplyEvent_ignoresNonStateChangedEvents() {
        let json = """
            {"type":"sceneUpdated","data":{"id":"light-1","attributes":{"isOn":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertNotEqual(
            state.devices.first(where: device(id: "light-1"))?.attributes.isOn,
            true
        )
    }

    func testApplyEvent_ignoresEventWithNoData() {
        let json = #"{"type":"deviceStateChanged"}"#
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)  // should not crash
    }

    func testApplyEvent_ignoresUnknownDeviceId() {
        state.applyEvent(event(id: "no-such-device", isOn: true))
        // No crash; nothing changed
        XCTAssertFalse(state.devices.contains { $0.attributes.isOn == true })
    }

    // MARK: Pinned state sync

    func testApplyEvent_syncsPinnedState_whenPinnedLightUpdated() {
        state.pinnedDeviceId = "light-1"
        state.pinnedDeviceIsOn = false
        state.applyEvent(event(id: "light-1", isOn: true))
        XCTAssertTrue(state.pinnedDeviceIsOn)
    }

    func testApplyEvent_doesNotSyncPinnedState_forSensorUpdate() {
        state.pinnedDeviceId = "light-1"
        state.pinnedDeviceIsOn = false
        let json = """
            {"type":"deviceStateChanged","data":{"id":"sensor-1","attributes":{"isOpen":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertFalse(state.pinnedDeviceIsOn)  // unchanged since light wasn't updated
    }
}
