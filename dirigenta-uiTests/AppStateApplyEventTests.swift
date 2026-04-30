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

// MARK: - Tests

@MainActor
final class AppStateApplyEventTests: XCTestCase {

    private var state: AppState!

    override func setUp() {
        super.setUp()
        state = AppState.preview()
        // Override preview lights with controlled fixtures
        state.lights = [
            makeDevice(id: "light-1", type: "light"),
            makeDevice(id: "light-2", type: "light"),
        ]
        state.sensors = [
            makeDevice(id: "sensor-1", type: "sensor", deviceType: "openCloseSensor"),
        ]
        state.envSensors = [
            makeDevice(id: "env-primary", type: "sensor", deviceType: "environmentSensor"),
        ]
        state.envSensorIdMap = [:]
    }

    // MARK: Light routing

    func testApplyEvent_updatesMatchingLight() {
        state.applyEvent(event(id: "light-1", isOn: true))
        XCTAssertEqual(state.lights[0].attributes.isOn, true)
        XCTAssertEqual(state.lights[1].attributes.isOn, false)  // unaffected
    }

    func testApplyEvent_updatesLightLevel() {
        state.applyEvent(event(id: "light-2", lightLevel: 75))
        XCTAssertEqual(state.lights[1].attributes.lightLevel, 75)
    }

    func testApplyEvent_doesNotTouchSensorsWhenLightMatches() {
        state.applyEvent(event(id: "light-1", isOn: true))
        XCTAssertFalse(state.sensors[0].attributes.isOn ?? false)
    }

    // MARK: Sensor routing

    func testApplyEvent_updatesMatchingSensor() {
        let json = """
            {"type":"deviceStateChanged","data":{"id":"sensor-1","attributes":{"isOpen":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertEqual(state.sensors[0].attributes.isOpen, true)
    }

    func testApplyEvent_doesNotTouchLightsWhenSensorMatches() {
        let json = """
            {"type":"deviceStateChanged","data":{"id":"sensor-1","attributes":{"isOpen":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertNil(state.lights[0].attributes.isOpen)
    }

    // MARK: Env sensor routing via idMap

    func testApplyEvent_routesComponentIdToPrimaryEnvSensor() {
        // Map component id "env-component" → primary "env-primary"
        state.envSensorIdMap = ["env-component": "env-primary"]
        let json = """
            {"type":"deviceStateChanged","data":{"id":"env-component","attributes":{"currentCO2":900.0}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertEqual(state.envSensors[0].attributes.currentCO2, 900.0)
    }

    func testApplyEvent_fallsBackToPrimaryId_whenNotInIdMap() {
        // Event id matches primary directly (no map entry needed)
        let json = """
            {"type":"deviceStateChanged","data":{"id":"env-primary","attributes":{"currentTemperature":22.5}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertEqual(state.envSensors[0].attributes.currentTemperature, 22.5)
    }

    // MARK: Guard conditions

    func testApplyEvent_ignoresNonStateChangedEvents() {
        let json = """
            {"type":"sceneUpdated","data":{"id":"light-1","attributes":{"isOn":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertNotEqual(state.lights[0].attributes.isOn, true)  // unchanged
    }

    func testApplyEvent_ignoresEventWithNoData() {
        let json = #"{"type":"deviceStateChanged"}"#
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)  // should not crash
    }

    func testApplyEvent_ignoresUnknownDeviceId() {
        state.applyEvent(event(id: "no-such-device", isOn: true))
        // No crash; nothing changed
        XCTAssertFalse(state.lights.contains { $0.attributes.isOn == true })
    }

    // MARK: Pinned state sync

    func testApplyEvent_syncsPinnedState_whenPinnedLightUpdated() {
        state.pinnedLightId = "light-1"
        state.pinnedLightIsOn = false
        state.applyEvent(event(id: "light-1", isOn: true))
        XCTAssertTrue(state.pinnedLightIsOn)
    }

    func testApplyEvent_doesNotSyncPinnedState_forSensorUpdate() {
        state.pinnedLightId = "light-1"
        state.pinnedLightIsOn = false
        let json = """
            {"type":"deviceStateChanged","data":{"id":"sensor-1","attributes":{"isOpen":true}}}
            """
        let e = try! JSONDecoder().decode(DirigeraEvent.self, from: json.data(using: .utf8)!)
        state.applyEvent(e)
        XCTAssertFalse(state.pinnedLightIsOn)  // unchanged since light wasn't updated
    }
}
