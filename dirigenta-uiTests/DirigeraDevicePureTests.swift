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

    // Light with no level and no color support → nil
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

    // lightLevel nil but color present → preset still returned
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

// MARK: - Generic switch fixtures

private func makeSwitch(
    id: String,
    relationId: String? = nil,
    switchGroup: Int? = nil,
    name: String = "Switch"
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.switchGroup = switchGroup
    return DirigeraDevice(
        id: id, type: "controller", deviceType: "genericSwitch",
        relationId: relationId, attributes: attrs
    )
}

// MARK: - Generic-switch merging via mergeByRelationId + collectSwitchGroups

private func mergeSwitches(_ devices: [DirigeraDevice]) -> [DirigeraDevice] {
    let (merged, _) = DirigeraDevice.mergeByRelationId(devices)
    return DirigeraDevice.collectSwitchGroups(
        merged: merged,
        components: devices
    )
}

@MainActor
final class GenericSwitchMergeTests: XCTestCase {

    func testMerge_empty_returnsEmpty() {
        XCTAssertTrue(mergeSwitches([]).isEmpty)
    }

    func testMerge_noRelationId_passesThrough() {
        let sw = makeSwitch(id: "sw1", switchGroup: 1)
        let result = mergeSwitches([sw])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "sw1")
    }

    func testMerge_sharedRelationId_producesOneDevice() {
        let result = mergeSwitches([
            makeSwitch(id: "sw1", relationId: "rel", switchGroup: 1),
            makeSwitch(id: "sw2", relationId: "rel", switchGroup: 2),
        ])
        XCTAssertEqual(result.count, 1)
    }

    func testMerge_collectsSwitchGroupsFromAllComponents() {
        let result = mergeSwitches([
            makeSwitch(id: "sw1", relationId: "rel", switchGroup: 1),
            makeSwitch(id: "sw2", relationId: "rel", switchGroup: 2),
            makeSwitch(id: "sw3", relationId: "rel", switchGroup: 3),
        ])
        let groups = result.first?.attributes.switchGroups ?? []
        XCTAssertEqual(groups.sorted(), [1, 2, 3])
    }

    func testMerge_nilSwitchGroup_excluded() {
        let result = mergeSwitches([
            makeSwitch(id: "sw1", relationId: "rel", switchGroup: 1),
            makeSwitch(id: "sw2", relationId: "rel", switchGroup: nil),
        ])
        let groups = result.first?.attributes.switchGroups ?? []
        XCTAssertEqual(groups, [1])
    }

    func testMerge_distinctRelationIds_separateOutputDevices() {
        let result = mergeSwitches([
            makeSwitch(id: "sw1", relationId: "rel-X", switchGroup: 1),
            makeSwitch(id: "sw2", relationId: "rel-Y", switchGroup: 1),
        ])
        XCTAssertEqual(result.count, 2)
    }

    func testMerge_noRelationId_notMergedWithRelationGroup() {
        let result = mergeSwitches([
            makeSwitch(id: "sw1", relationId: "rel", switchGroup: 1),
            makeSwitch(id: "sw2", relationId: nil, switchGroup: 2),
        ])
        // One merged entry for "rel" + one standalone = 2 total
        XCTAssertEqual(result.count, 2)
    }
}

// MARK: - Smart-plug fixtures

private func makePlugOutlet(
    id: String,
    relationId: String? = nil,
    isOn: Bool = false,
    name: String = "Plug"
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.isOn = isOn
    return DirigeraDevice(
        id: id, type: "outlet", deviceType: "outlet",
        relationId: relationId, attributes: attrs
    )
}

private func makePlugMeter(
    id: String,
    relationId: String? = nil,
    power: Double? = nil,
    amps: Double? = nil,
    totalEnergy: Double? = nil,
    name: String = "Plug"
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.currentActivePower = power
    attrs.currentAmps = amps
    attrs.totalEnergyConsumed = totalEnergy
    return DirigeraDevice(
        id: id, type: "outlet",
        relationId: relationId, attributes: attrs
    )
}

private func mergePlugs(_ devices: [DirigeraDevice]) -> [DirigeraDevice] {
    let sorted = devices.sorted { $0.id < $1.id }
    let (merged, _) = DirigeraDevice.mergeByRelationId(sorted)
    return DirigeraDevice.collectOutletIds(merged: merged, components: sorted)
}

@MainActor
final class SmartPlugMergeTests: XCTestCase {

    func testMerge_empty_returnsEmpty() {
        XCTAssertTrue(mergePlugs([]).isEmpty)
    }

    func testMerge_pairCollapsesIntoOnePlug() {
        let result = mergePlugs([
            makePlugOutlet(id: "p1-outlet", relationId: "rel", isOn: true),
            makePlugMeter(
                id: "p1-meter", relationId: "rel", power: 50.0, amps: 0.2,
                totalEnergy: 1234
            ),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isSmartPlug)
        XCTAssertEqual(result[0].attributes.outletId, "p1-outlet")
        // Attributes from both components folded in
        XCTAssertEqual(result[0].attributes.isOn, true)
        XCTAssertEqual(result[0].attributes.currentActivePower, 50.0)
        XCTAssertEqual(result[0].attributes.currentAmps, 0.2)
        XCTAssertEqual(result[0].attributes.totalEnergyConsumed, 1234)
    }

    func testMerge_twoDistinctPlugs_produceTwoMergedDevices() {
        let result = mergePlugs([
            makePlugOutlet(id: "a-outlet", relationId: "rel-a", isOn: true),
            makePlugMeter(id: "a-meter", relationId: "rel-a", power: 10.0),
            makePlugOutlet(id: "b-outlet", relationId: "rel-b", isOn: false),
            makePlugMeter(id: "b-meter", relationId: "rel-b", power: 20.0),
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.isSmartPlug })
    }

    func testMerge_outletWithoutMeter_stillSmartPlug() {
        let result = mergePlugs([
            makePlugOutlet(id: "p1", isOn: true)  // no relationId, standalone
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isSmartPlug)
        XCTAssertEqual(result[0].attributes.outletId, "p1")
    }

    func testMerge_meterWithoutOutlet_isNotSmartPlug() {
        // A meter with no outlet sibling — outletId stays nil, so isSmartPlug is false.
        let result = mergePlugs([
            makePlugMeter(id: "m1", relationId: "orphan-rel", power: 5.0)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isSmartPlug)
        XCTAssertNil(result[0].attributes.outletId)
    }

    func testArrayExtension_smartPlugs_filtersCorrectly() {
        let merged = mergePlugs([
            makePlugOutlet(id: "p1-outlet", relationId: "rel", isOn: true),
            makePlugMeter(id: "p1-meter", relationId: "rel"),
        ])
        let withLight = merged + [makeLight()]
        XCTAssertEqual(withLight.smartPlugs.count, 1)
        XCTAssertEqual(withLight.lights.count, 1)
        // Plugs are NOT in `others` — they have their own bucket.
        XCTAssertEqual(withLight.others.count, 0)
    }

    func testArrayExtension_motionSensorClassifiesAsOther() {
        // Motion sensors stay in `others` (they render with a dedicated row
        // inside that section), and are excluded from every other bucket.
        var attrs = DirigeraDevice.Attributes()
        attrs.isDetected = false
        let motion = DirigeraDevice(
            id: "m1", type: "sensor", deviceType: "occupancySensor",
            attributes: attrs
        )
        let all: [DirigeraDevice] = [motion, makeLight()]
        XCTAssertEqual(all.others.count, 1)
        XCTAssertEqual(all.others.first?.id, "m1")
        XCTAssertEqual(all.lights.count, 1)
        XCTAssertEqual(all.envSensors.count, 0)
        XCTAssertEqual(all.openCloseSensors.count, 0)
        XCTAssertEqual(all.smartPlugs.count, 0)
    }
}
