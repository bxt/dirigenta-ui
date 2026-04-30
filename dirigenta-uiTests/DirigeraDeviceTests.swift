import XCTest

@testable import dirigenta_ui

// MARK: - Fixtures

private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T
{
    try JSONDecoder().decode(type, from: json.data(using: .utf8)!)
}

private func makeDevice(
    id: String = "d1",
    type: String = "light",
    deviceType: String? = nil,
    relationId: String? = nil,
    attributes: String = "{}"
) -> DirigeraDevice {
    let json = """
        {
          "id": "\(id)",
          "type": "\(type)",
          \(deviceType.map { "\"deviceType\": \"\($0)\"," } ?? "")
          \(relationId.map { "\"relationId\": \"\($0)\"," } ?? "")
          "isReachable": true,
          "attributes": \(attributes)
        }
        """
    return try! decode(DirigeraDevice.self, from: json)
}

// MARK: - DirigeraDevice decoding

@MainActor
final class DirigeraDeviceDecodingTests: XCTestCase {

    func testDecodesMinimalDevice() throws {
        let device = makeDevice(id: "abc", type: "light")
        XCTAssertEqual(device.id, "abc")
        XCTAssertEqual(device.type, "light")
    }

    func testDecodesFullAttributes() throws {
        let device = makeDevice(
            attributes: """
                {
                  "customName": "Floor Lamp",
                  "isOn": true,
                  "lightLevel": 80,
                  "colorTemperature": 2700,
                  "colorTemperatureMin": 2202,
                  "colorTemperatureMax": 4000,
                  "colorHue": 120.5,
                  "colorSaturation": 0.8,
                  "batteryPercentage": 95
                }
                """
        )
        XCTAssertEqual(device.attributes.customName, "Floor Lamp")
        XCTAssertEqual(device.attributes.isOn, true)
        XCTAssertEqual(device.attributes.lightLevel, 80)
        XCTAssertEqual(device.attributes.colorTemperature, 2700)
        XCTAssertEqual(device.attributes.colorTemperatureMin, 2202)
        XCTAssertEqual(device.attributes.colorTemperatureMax, 4000)
        XCTAssertEqual(device.attributes.colorHue!, 120.5, accuracy: 0.01)
        XCTAssertEqual(device.attributes.colorSaturation!, 0.8, accuracy: 0.01)
        XCTAssertEqual(device.attributes.batteryPercentage, 95)
    }

    func testDecodesEnvSensorAttributes() throws {
        let device = makeDevice(
            deviceType: "environmentSensor",
            attributes: """
                {
                  "currentTemperature": 22.5,
                  "currentRH": 45.0,
                  "currentCO2": 850.0,
                  "currentPM25": 8.0
                }
                """
        )
        XCTAssertEqual(
            device.attributes.currentTemperature!,
            22.5,
            accuracy: 0.01
        )
        XCTAssertEqual(device.attributes.currentRH!, 45.0, accuracy: 0.01)
        XCTAssertEqual(device.attributes.currentCO2!, 850.0, accuracy: 0.01)
        XCTAssertEqual(device.attributes.currentPM25!, 8.0, accuracy: 0.01)
    }

    func testDecodesDeviceArray() throws {
        let json = """
            [
              {"id": "a", "type": "light", "isReachable": true, "attributes": {}},
              {"id": "b", "type": "gateway", "isReachable": true, "attributes": {}}
            ]
            """
        let devices = try decode([DirigeraDevice].self, from: json)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, "a")
        XCTAssertEqual(devices[1].id, "b")
    }
}

// MARK: - DirigeraDevice computed properties

@MainActor
final class DirigeraDevicePropertiesTests: XCTestCase {

    func testDisplayName_usesCustomName() {
        let d = makeDevice(id: "x", attributes: #"{"customName": "Bedside"}"#)
        XCTAssertEqual(d.displayName, "Bedside")
    }

    func testDisplayName_fallsBackToId() {
        let d = makeDevice(id: "abc-123")
        XCTAssertEqual(d.displayName, "abc-123")
    }

    func testIsOn_defaultsFalseWhenNil() {
        let d = makeDevice()
        XCTAssertFalse(d.isOn)
    }

    func testIsOn_trueWhenSet() {
        let d = makeDevice(attributes: #"{"isOn": true}"#)
        XCTAssertTrue(d.isOn)
    }

    func testIsOpen_defaultsFalseWhenNil() {
        let d = makeDevice(type: "sensor", deviceType: "openCloseSensor")
        XCTAssertFalse(d.isOpen)
    }

    func testIsLight() {
        XCTAssertTrue(makeDevice(type: "light").isLight)
        XCTAssertFalse(makeDevice(type: "gateway").isLight)
    }

    func testIsGateway() {
        XCTAssertTrue(makeDevice(type: "gateway").isGateway)
        XCTAssertFalse(makeDevice(type: "light").isGateway)
    }

    func testIsOpenCloseSensor() {
        XCTAssertTrue(
            makeDevice(type: "sensor", deviceType: "openCloseSensor")
                .isOpenCloseSensor
        )
        XCTAssertFalse(
            makeDevice(type: "sensor", deviceType: "environmentSensor")
                .isOpenCloseSensor
        )
    }

    func testIsEnvironmentSensor() {
        XCTAssertTrue(
            makeDevice(type: "sensor", deviceType: "environmentSensor")
                .isEnvironmentSensor
        )
        XCTAssertFalse(
            makeDevice(type: "sensor", deviceType: "openCloseSensor")
                .isEnvironmentSensor
        )
    }

    func testIsColorTemperatureLight_trueWhenMinSet() {
        let d = makeDevice(attributes: #"{"colorTemperatureMin": 2200}"#)
        XCTAssertTrue(d.isColorTemperatureLight)
    }

    func testIsColorTemperatureLight_falseWhenMinAbsent() {
        XCTAssertFalse(makeDevice().isColorTemperatureLight)
    }

    func testIsColorLight_trueWhenHueSet() {
        let d = makeDevice(attributes: #"{"colorHue": 120.0}"#)
        XCTAssertTrue(d.isColorLight)
    }

    func testIsColorLight_falseWhenHueAbsent() {
        XCTAssertFalse(makeDevice().isColorLight)
    }

    func testSupportsColorControls_trueForColorTemperatureLight() {
        let d = makeDevice(attributes: #"{"colorTemperatureMin": 2200}"#)
        XCTAssertTrue(d.supportsColorControls)
    }

    func testSupportsColorControls_trueForColorLight() {
        let d = makeDevice(attributes: #"{"colorHue": 120.0}"#)
        XCTAssertTrue(d.supportsColorControls)
    }

    func testSupportsColorControls_falseForPlainLight() {
        XCTAssertFalse(makeDevice(type: "light").supportsColorControls)
    }
}

// MARK: - Environment sensor readings

@MainActor
final class DirigeraDeviceEnvReadingsTests: XCTestCase {

    private func sensor(
        temp: Double? = nil,
        rh: Double? = nil,
        co2: Double? = nil,
        pm25: Double? = nil
    ) -> DirigeraDevice {
        var parts: [String] = []
        if let t = temp { parts.append(#""currentTemperature": \#(t)"#) }
        if let r = rh { parts.append(#""currentRH": \#(r)"#) }
        if let c = co2 { parts.append(#""currentCO2": \#(c)"#) }
        if let p = pm25 { parts.append(#""currentPM25": \#(p)"#) }
        return makeDevice(
            deviceType: "environmentSensor",
            attributes: "{\(parts.joined(separator: ","))}"
        )
    }

    func testEnvReadings_empty_whenNoAttributes() {
        XCTAssertTrue(sensor().envReadings.isEmpty)
    }

    func testEnvReadings_temperature_inRange() {
        let reading = sensor(temp: 22.0).envReadings[0]
        XCTAssertEqual(reading.text, "22.0°C")
        XCTAssertFalse(reading.outOfRange)
    }

    func testEnvReadings_temperature_outOfRange_low() {
        XCTAssertTrue(sensor(temp: 17.9).envReadings[0].outOfRange)
    }

    func testEnvReadings_temperature_outOfRange_high() {
        XCTAssertTrue(sensor(temp: 26.1).envReadings[0].outOfRange)
    }

    func testEnvReadings_rh_inRange() {
        let reading = sensor(rh: 50.0).envReadings[0]
        XCTAssertEqual(reading.text, "50% RH")
        XCTAssertFalse(reading.outOfRange)
    }

    func testEnvReadings_rh_outOfRange_low() {
        XCTAssertTrue(sensor(rh: 29.0).envReadings[0].outOfRange)
    }

    func testEnvReadings_rh_outOfRange_high() {
        XCTAssertTrue(sensor(rh: 61.0).envReadings[0].outOfRange)
    }

    func testEnvReadings_co2_inRange() {
        let reading = sensor(co2: 900.0).envReadings[0]
        XCTAssertEqual(reading.text, "900 ppm CO₂")
        XCTAssertFalse(reading.outOfRange)
    }

    func testEnvReadings_co2_outOfRange() {
        XCTAssertTrue(sensor(co2: 1001.0).envReadings[0].outOfRange)
    }

    func testEnvReadings_pm25_inRange() {
        let reading = sensor(pm25: 10.0).envReadings[0]
        XCTAssertEqual(reading.text, "10 µg/m³ PM2.5")
        XCTAssertFalse(reading.outOfRange)
    }

    func testEnvReadings_pm25_outOfRange() {
        XCTAssertTrue(sensor(pm25: 13.0).envReadings[0].outOfRange)
    }

    func testIsComfortable_trueWhenAllInRange() {
        XCTAssertTrue(
            sensor(temp: 22.0, rh: 50.0, co2: 600.0, pm25: 5.0).isComfortable
        )
    }

    func testIsComfortable_falseWhenAnyOutOfRange() {
        XCTAssertFalse(
            sensor(temp: 22.0, rh: 50.0, co2: 1200.0, pm25: 5.0).isComfortable
        )
    }
}

// MARK: - Merging

@MainActor
final class DirigeraDeviceMergingTests: XCTestCase {

    func testAttributesMerging_coalesces_nonNilFields() throws {
        var merged = try decode(
            DirigeraDevice.Attributes.self,
            from: #"{"customName":"Old Name","lightLevel":50}"#
        )
        let update = try decode(
            DirigeraDevice.Attributes.self,
            from: #"{"lightLevel":80,"isOn":true}"#
        )
        merged.merge(update)
        XCTAssertEqual(merged.customName, "Old Name")  // kept from base
        XCTAssertEqual(merged.lightLevel, 80)  // overwritten
        XCTAssertEqual(merged.isOn, true)  // added
    }

    func testAttributesMerging_withNil_returnsBase() throws {
        var merged = try decode(
            DirigeraDevice.Attributes.self,
            from: #"{"customName":"Kept"}"#
        )
        merged.merge(nil as DirigeraDevice.Attributes?)
        XCTAssertEqual(merged.customName, "Kept")
    }

    func testDeviceMerging_withEventData_updatesState() throws {
        var updated = makeDevice(
            id: "d1",
            type: "light",
            attributes: #"{"isOn": false, "lightLevel": 50}"#
        )

        let eventJSON = """
            {
              "type": "deviceStateChanged",
              "data": {
                "id": "d1",
                "attributes": {"isOn": true, "lightLevel": 90}
              }
            }
            """
        let event = try decode(DirigeraEvent.self, from: eventJSON)
        updated.merge(event.data!)

        XCTAssertEqual(updated.id, "d1")
        XCTAssertEqual(updated.attributes.isOn, true)
        XCTAssertEqual(updated.attributes.lightLevel, 90)
    }

    func testMergeEnvSensors_combinesComponentsByRelationId() {
        let s1 = makeDevice(
            id: "s1",
            type: "sensor",
            deviceType: "environmentSensor",
            relationId: "rel-1",
            attributes:
                #"{"customName": "STARKVIND Table", "currentCO2": 700.0}"#
        )
        let s2 = makeDevice(
            id: "s2",
            type: "sensor",
            deviceType: "environmentSensor",
            relationId: "rel-1",
            attributes:
                #"{"customName": "STARKVIND Table", "currentPM25": 5.0}"#
        )

        let (merged, idMap) = DirigeraDevice.mergeEnvSensors([s1, s2])

        XCTAssertEqual(merged.count, 1)
        XCTAssertNotNil(merged[0].attributes.currentCO2)
        XCTAssertNotNil(merged[0].attributes.currentPM25)
        XCTAssertEqual(idMap["s1"], idMap["s2"])
    }

    func testMergeEnvSensors_preservesUnrelatedSensors() {
        let standalone = makeDevice(
            id: "s1",
            type: "sensor",
            deviceType: "environmentSensor"
        )
        let (merged, idMap) = DirigeraDevice.mergeEnvSensors([standalone])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "s1")
        XCTAssertTrue(idMap.isEmpty)
    }

    func testMergeEnvSensors_prefersNamedComponentOverDefault() {
        // One component has customName == model (IKEA default), the other has a user-set name.
        let generic = makeDevice(
            id: "s1",
            type: "sensor",
            deviceType: "environmentSensor",
            relationId: "rel-1",
            attributes: #"{"customName": "STARKVIND", "model": "STARKVIND"}"#
        )
        let named = makeDevice(
            id: "s2",
            type: "sensor",
            deviceType: "environmentSensor",
            relationId: "rel-1",
            attributes:
                #"{"customName": "Living Room Air", "model": "STARKVIND"}"#
        )

        let (merged, _) = DirigeraDevice.mergeEnvSensors([generic, named])
        XCTAssertEqual(merged[0].attributes.customName, "Living Room Air")
    }

    func testMergeEnvSensors_picksRoomFromSensorThatHasOne() throws {
        let noRoom = try decode(
            DirigeraDevice.self,
            from: """
                {"id":"s1","type":"sensor","deviceType":"environmentSensor",
                 "relationId":"rel-1","isReachable":true,"attributes":{"customName":"STARKVIND","currentCO2":700.0}}
                """
        )
        let withRoom = try decode(
            DirigeraDevice.self,
            from: """
                {"id":"s2","type":"sensor","deviceType":"environmentSensor",
                 "relationId":"rel-1","isReachable":true,
                 "room":{"id":"r1","name":"Living Room"},
                 "attributes":{"customName":"STARKVIND","currentPM25":5.0}}
                """
        )

        let (merged, _) = DirigeraDevice.mergeEnvSensors([noRoom, withRoom])
        XCTAssertEqual(merged[0].room?.name, "Living Room")
    }
}

// MARK: - DirigeraEvent decoding

@MainActor
final class DirigeraEventTests: XCTestCase {

    func testIsDeviceStateChanged_true() throws {
        let event = try decode(
            DirigeraEvent.self,
            from: #"{"type": "deviceStateChanged"}"#
        )
        XCTAssertTrue(event.isDeviceStateChanged)
    }

    func testIsDeviceStateChanged_false() throws {
        let event = try decode(
            DirigeraEvent.self,
            from: #"{"type": "sceneUpdated"}"#
        )
        XCTAssertFalse(event.isDeviceStateChanged)
    }

    func testDecodesPartialAttributes() throws {
        let json = """
            {
              "type": "deviceStateChanged",
              "data": {
                "id": "light-1",
                "attributes": {"isOn": false}
              }
            }
            """
        let event = try decode(DirigeraEvent.self, from: json)
        XCTAssertEqual(event.data?.id, "light-1")
        XCTAssertEqual(event.data?.attributes?.isOn, false)
        XCTAssertNil(event.data?.attributes?.lightLevel)
    }

    func testDecodesEventWithNoData() throws {
        let event = try decode(DirigeraEvent.self, from: #"{"type": "ping"}"#)
        XCTAssertNil(event.data)
    }
}
