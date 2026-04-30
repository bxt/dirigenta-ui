import XCTest

@testable import dirigenta_ui

// MARK: - Fixtures

private func makeLight(
    id: String = "l1",
    lightLevel: Int? = nil,
    colorHue: Double? = nil,
    colorSaturation: Double? = nil,
    colorTemperature: Int? = nil,
    colorTemperatureMin: Int? = nil,
    colorMode: String? = nil
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.lightLevel = lightLevel
    attrs.colorHue = colorHue
    attrs.colorSaturation = colorSaturation
    attrs.colorTemperature = colorTemperature
    attrs.colorTemperatureMin = colorTemperatureMin
    attrs.colorMode = colorMode
    return DirigeraDevice(id: id, type: "light", attributes: attrs)
}

private func makeSensor(id: String = "s1", lastSeen: String) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.isOpen = true
    var d = DirigeraDevice(id: id, type: "sensor", deviceType: "openCloseSensor", attributes: attrs)
    d.lastSeen = lastSeen
    return d
}

// MARK: - #5  DirigeraDevice.colorPreset branches

@MainActor
final class ColorPresetTests: XCTestCase {

    // Non-light types always return nil
    func testColorPreset_nilForNonLight() {
        var d = makeLight()
        d.type = "gateway"
        XCTAssertNil(d.colorPreset)
    }

    // Light with no level and no colour support → nil
    func testColorPreset_nilForBareLight() {
        XCTAssertNil(makeLight().colorPreset)
    }

    // Level-only light
    func testColorPreset_levelOnly() {
        let d = makeLight(lightLevel: 60)
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertEqual(p.lightLevel, 60)
        XCTAssertNil(p.hue)
        XCTAssertNil(p.colorTemperature)
    }

    // colorMode == "color" → hue/sat branch
    func testColorPreset_colorMode_color_usesHueSat() {
        let d = makeLight(
            lightLevel: 80,
            colorHue: 200.0,
            colorSaturation: 0.9,
            colorMode: "color"
        )
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertEqual(p.hue!, 200.0, accuracy: 0.001)
        XCTAssertEqual(p.saturation!, 0.9, accuracy: 0.001)
        XCTAssertEqual(p.lightLevel, 80)
        XCTAssertNil(p.colorTemperature)
    }

    // colorMode == "temperature" → CT branch
    func testColorPreset_colorMode_temperature_usesCT() {
        let d = makeLight(
            lightLevel: 70,
            colorTemperature: 3000,
            colorTemperatureMin: 2200,
            colorMode: "temperature"
        )
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertEqual(p.colorTemperature, 3000)
        XCTAssertEqual(p.lightLevel, 70)
        XCTAssertNil(p.hue)
    }

    // colorMode == nil → prefers hue/sat if present
    func testColorPreset_nilColorMode_prefersHueSat() {
        let d = makeLight(
            lightLevel: 50,
            colorHue: 120.0,
            colorSaturation: 1.0,
            colorTemperature: 4000,
            colorTemperatureMin: 2200
        )
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertNotNil(p.hue)
        XCTAssertNil(p.colorTemperature)
    }

    // colorMode == nil, no hue → falls back to CT
    func testColorPreset_nilColorMode_fallsBackToCT() {
        let d = makeLight(
            lightLevel: 50,
            colorTemperature: 4000,
            colorTemperatureMin: 2200
        )
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertEqual(p.colorTemperature, 4000)
        XCTAssertNil(p.hue)
    }

    // colorMode == "color" but hue/sat missing → falls back to level-only
    func testColorPreset_colorMode_color_missingHueSat_fallsBackToLevel() {
        let d = makeLight(lightLevel: 90, colorMode: "color")
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertEqual(p.lightLevel, 90)
        XCTAssertNil(p.hue)
        XCTAssertNil(p.colorTemperature)
    }

    // colorMode == "temperature" but CT missing → falls back to level-only
    func testColorPreset_colorMode_temperature_missingCT_fallsBackToLevel() {
        let d = makeLight(lightLevel: 90, colorTemperatureMin: 2200, colorMode: "temperature")
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertEqual(p.lightLevel, 90)
        XCTAssertNil(p.colorTemperature)
    }

    // lightLevel nil but colour present → preset still returned
    func testColorPreset_nilLevel_withColor() {
        let d = makeLight(colorHue: 30.0, colorSaturation: 0.5, colorMode: "color")
        let p = try! XCTUnwrap(d.colorPreset)
        XCTAssertNil(p.lightLevel)
        XCTAssertNotNil(p.hue)
    }
}

// MARK: - #9  DirigeraDevice.openSeconds / openDuration

@MainActor
final class OpenDurationTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    func testOpenSeconds_returnsElapsedSeconds() {
        let lastSeen = "2024-01-01T12:00:00.000Z"
        let now = date("2024-01-01T12:00:45.000Z")
        let d = makeSensor(lastSeen: lastSeen)
        XCTAssertEqual(d.openSeconds(now: now), 45)
    }

    func testOpenSeconds_returnsNil_whenLastSeenNil() {
        var d = makeSensor(lastSeen: "2024-01-01T12:00:00.000Z")
        d.lastSeen = nil
        XCTAssertNil(d.openSeconds(now: Date()))
    }

    func testOpenSeconds_returnsNil_whenNowIsBeforeLastSeen() {
        // Clocks skew / future timestamp → should return nil, not a negative duration
        let lastSeen = "2024-01-01T12:00:10.000Z"
        let now = date("2024-01-01T12:00:00.000Z")
        let d = makeSensor(lastSeen: lastSeen)
        XCTAssertNil(d.openSeconds(now: now))
    }

    func testOpenSeconds_parsesPlainISOWithoutFractionalSeconds() {
        // Falls back to isoPlain formatter when fractional seconds absent
        let lastSeen = "2024-01-01T12:00:00Z"
        let now = date("2024-01-01T12:00:30.000Z")
        let d = makeSensor(lastSeen: lastSeen)
        XCTAssertEqual(d.openSeconds(now: now), 30)
    }

    func testOpenSeconds_returnsNil_forMalformedDate() {
        let d = makeSensor(lastSeen: "not-a-date")
        XCTAssertNil(d.openSeconds(now: Date()))
    }

    func testOpenDuration_formatsHoursMinutesSeconds() {
        let lastSeen = "2024-01-01T12:00:00.000Z"
        // 1h 23m 45s = 5025s
        let now = date("2024-01-01T13:23:45.000Z")
        let d = makeSensor(lastSeen: lastSeen)
        XCTAssertEqual(d.openDuration(now: now), "01:23:45")
    }

    func testOpenDuration_zero_padsSingleDigitValues() {
        let lastSeen = "2024-01-01T12:00:00.000Z"
        let now = date("2024-01-01T12:01:05.000Z")  // 65s = 0h 1m 5s
        let d = makeSensor(lastSeen: lastSeen)
        XCTAssertEqual(d.openDuration(now: now), "00:01:05")
    }

    func testOpenDuration_returnsNil_whenLastSeenNil() {
        var d = makeSensor(lastSeen: "2024-01-01T12:00:00.000Z")
        d.lastSeen = nil
        XCTAssertNil(d.openDuration(now: Date()))
    }

    func testOpenDuration_largeValue_doesNotWrapHours() {
        let lastSeen = "2024-01-01T00:00:00.000Z"
        let now = date("2024-01-02T02:03:04.000Z")  // 26h 3m 4s
        let d = makeSensor(lastSeen: lastSeen)
        XCTAssertEqual(d.openDuration(now: now), "26:03:04")
    }
}
