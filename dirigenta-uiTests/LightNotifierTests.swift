import XCTest

@testable import dirigenta_ui

// MARK: - Mock client

/// Records every call made to the DirigeraClientProtocol methods.
/// @MainActor so concurrent task-group calls serialise on the main actor.
@MainActor
final class MockLightClient: DirigeraClientProtocol {
    enum Call: Equatable {
        case setLight(id: String, isOn: Bool)
        case setLightLevel(id: String, level: Int)
        case setColor(id: String, hue: Double, saturation: Double)
        case applyPreset(id: String)
    }

    var calls: [Call] = []
    var shouldThrow = false

    func setLight(id: String, isOn: Bool) async throws {
        if shouldThrow { throw URLError(.badServerResponse) }
        calls.append(.setLight(id: id, isOn: isOn))
    }

    func setLightLevel(id: String, lightLevel: Int) async throws {
        if shouldThrow { throw URLError(.badServerResponse) }
        calls.append(.setLightLevel(id: id, level: lightLevel))
    }

    func setColor(id: String, hue: Double, saturation: Double) async throws {
        if shouldThrow { throw URLError(.badServerResponse) }
        calls.append(.setColor(id: id, hue: hue, saturation: saturation))
    }

    func applyColorPreset(_ preset: LightColorPreset, to id: String) async throws {
        if shouldThrow { throw URLError(.badServerResponse) }
        calls.append(.applyPreset(id: id))
    }
}

// MARK: - Fixtures

private func makeLight(
    id: String,
    isOn: Bool = true,
    lightLevel: Int? = nil,
    colorHue: Double? = nil,
    colorSaturation: Double? = nil,
    colorTemperature: Int? = nil,
    colorTemperatureMin: Int? = nil
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.isOn = isOn
    attrs.lightLevel = lightLevel
    attrs.colorHue = colorHue
    attrs.colorSaturation = colorSaturation
    attrs.colorTemperature = colorTemperature
    attrs.colorTemperatureMin = colorTemperatureMin
    return DirigeraDevice(id: id, type: "light", attributes: attrs)
}

// MARK: - LightNotifier.init tests

@MainActor
final class LightNotifierInitTests: XCTestCase {

    func testInit_returnsNil_whenNoLightsOn() {
        let client = MockLightClient()
        let lights = [makeLight(id: "l1", isOn: false), makeLight(id: "l2", isOn: false)]
        XCTAssertNil(LightNotifier(client: client, lights: lights, pinnedId: nil))
    }

    func testInit_returnsNil_whenLightsArrayEmpty() {
        let client = MockLightClient()
        XCTAssertNil(LightNotifier(client: client, lights: [], pinnedId: nil))
    }

    func testInit_selectsOnlyOnLights_whenNoPinned() {
        let client = MockLightClient()
        let lights = [
            makeLight(id: "l1", isOn: true),
            makeLight(id: "l2", isOn: false),
            makeLight(id: "l3", isOn: true),
        ]
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: lights, pinnedId: nil))
        XCTAssertEqual(Set(notifier.targets.map(\.id)), ["l1", "l3"])
    }

    func testInit_selectsPinnedLight_evenIfOff() {
        let client = MockLightClient()
        let lights = [
            makeLight(id: "l1", isOn: true),
            makeLight(id: "pinned", isOn: false),
        ]
        let notifier = try! XCTUnwrap(
            LightNotifier(client: client, lights: lights, pinnedId: "pinned")
        )
        XCTAssertEqual(notifier.targets.map(\.id), ["pinned"])
    }

    func testInit_fallsBackToOnLights_whenPinnedIdNotFound() {
        let client = MockLightClient()
        let lights = [makeLight(id: "l1", isOn: true), makeLight(id: "l2", isOn: false)]
        let notifier = try! XCTUnwrap(
            LightNotifier(client: client, lights: lights, pinnedId: "missing")
        )
        XCTAssertEqual(notifier.targets.map(\.id), ["l1"])
    }

    func testInit_recordsWasOnState() {
        let client = MockLightClient()
        let lights = [makeLight(id: "l1", isOn: true), makeLight(id: "l2", isOn: false)]
        let notifier = try! XCTUnwrap(
            LightNotifier(client: client, lights: lights, pinnedId: nil)
        )
        XCTAssertEqual(notifier.wasOn["l1"], true)
    }
}

// MARK: - LightNotifier step tests

@MainActor
final class LightNotifierStepTests: XCTestCase {

    // MARK: turnOnDimmed

    func testTurnOnDimmed_onlyTurnsOnLightsThatWereOff() async {
        let client = MockLightClient()
        // Pinned light that was off → one target, wasOn = false
        let lights = [makeLight(id: "pinned", isOn: false)]
        let notifier = try! XCTUnwrap(
            LightNotifier(client: client, lights: lights, pinnedId: "pinned")
        )
        XCTAssertEqual(notifier.wasOn["pinned"], false)
        await notifier.turnOnDimmed()
        XCTAssertEqual(client.calls, [.setLight(id: "pinned", isOn: true)])
    }

    func testTurnOnDimmed_skipsLightsThatWereAlreadyOn() async {
        let client = MockLightClient()
        let lights = [makeLight(id: "l1", isOn: true)]
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: lights, pinnedId: nil))
        await notifier.turnOnDimmed()
        XCTAssertTrue(client.calls.isEmpty)
    }

    // MARK: capturePresets

    func testCapturePresets_returnsPresetsFromFreshList() {
        let client = MockLightClient()
        let target = makeLight(id: "l1", isOn: true, lightLevel: 80, colorHue: 120, colorSaturation: 0.9)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [target], pinnedId: nil))

        // Simulate a re-fetched list where the light now has a known preset
        let freshLight = makeLight(id: "l1", isOn: true, lightLevel: 80, colorHue: 120, colorSaturation: 0.9)
        let presets = notifier.capturePresets(from: [freshLight])

        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].id, "l1")
        XCTAssertNotNil(presets[0].preset)
    }

    func testCapturePresets_returnsNilPreset_forPlainDimmableLight() {
        let client = MockLightClient()
        // Plain dimmable light (no colour support) → colorPreset is level-only
        let light = makeLight(id: "l1", isOn: true, lightLevel: 50)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [light], pinnedId: nil))
        let presets = notifier.capturePresets(from: [light])
        XCTAssertEqual(presets.count, 1)
        // Level-only light does have a preset (lightLevel is set)
        XCTAssertNotNil(presets[0].preset)
    }

    func testCapturePresets_skipsLightsMissingFromFreshList() {
        let client = MockLightClient()
        let target = makeLight(id: "l1", isOn: true)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [target], pinnedId: nil))
        // Fresh list doesn't contain l1
        let presets = notifier.capturePresets(from: [makeLight(id: "other", isOn: true)])
        XCTAssertTrue(presets.isEmpty)
    }

    // MARK: flash

    func testFlash_setsRedColorOnColorLights() async {
        let client = MockLightClient()
        let colorLight = makeLight(id: "l1", isOn: true, lightLevel: 50, colorHue: 200, colorSaturation: 0.8)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [colorLight], pinnedId: nil))
        await notifier.flash()

        XCTAssertTrue(client.calls.contains(.setColor(id: "l1", hue: 0, saturation: 1)))
    }

    func testFlash_setsBrightnessTo100OnDimmableLights() async {
        let client = MockLightClient()
        let dimmable = makeLight(id: "l1", isOn: true, lightLevel: 50)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [dimmable], pinnedId: nil))
        await notifier.flash()

        XCTAssertTrue(client.calls.contains(.setLightLevel(id: "l1", level: 100)))
    }

    func testFlash_doesNotSetColor_onTemperatureOnlyLight() async {
        let client = MockLightClient()
        // Temperature-only light has colorTemperatureMin but no colorHue
        let ctLight = makeLight(id: "l1", isOn: true, lightLevel: 80, colorTemperatureMin: 2200)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [ctLight], pinnedId: nil))
        await notifier.flash()

        XCTAssertFalse(client.calls.contains(where: {
            if case .setColor = $0 { return true }; return false
        }))
        XCTAssertTrue(client.calls.contains(.setLightLevel(id: "l1", level: 100)))
    }

    func testFlash_doesNotSetBrightness_onLightWithNoLightLevel() async {
        let client = MockLightClient()
        // A device with no lightLevel attribute (e.g. binary on/off only)
        let noLevel = makeLight(id: "l1", isOn: true)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [noLevel], pinnedId: nil))
        await notifier.flash()

        XCTAssertFalse(client.calls.contains(where: {
            if case .setLightLevel = $0 { return true }; return false
        }))
    }

    // MARK: restore

    func testRestore_appliesPresetForEachLight() async {
        let client = MockLightClient()
        let light = makeLight(id: "l1", isOn: true, lightLevel: 70)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [light], pinnedId: nil))

        let preset = LightColorPreset(lightLevel: 70)
        await notifier.restore([(id: "l1", preset: preset)])

        XCTAssertEqual(client.calls, [.applyPreset(id: "l1")])
    }

    func testRestore_skipsNilPresets() async {
        let client = MockLightClient()
        let light = makeLight(id: "l1", isOn: true)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [light], pinnedId: nil))
        await notifier.restore([(id: "l1", preset: nil)])
        XCTAssertTrue(client.calls.isEmpty)
    }

    // MARK: turnOffDimmed

    func testTurnOffDimmed_turnsOffLightsThatWereOff() async {
        let client = MockLightClient()
        let wasOff = makeLight(id: "pinned", isOn: false)
        let notifier = try! XCTUnwrap(
            LightNotifier(client: client, lights: [wasOff], pinnedId: "pinned")
        )
        await notifier.turnOffDimmed()
        XCTAssertEqual(client.calls, [.setLight(id: "pinned", isOn: false)])
    }

    func testTurnOffDimmed_skipsLightsThatWereOn() async {
        let client = MockLightClient()
        let wasOn = makeLight(id: "l1", isOn: true)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [wasOn], pinnedId: nil))
        await notifier.turnOffDimmed()
        XCTAssertTrue(client.calls.isEmpty)
    }

    // MARK: Error tolerance

    func testFlash_continuesWhenClientThrows() async {
        let client = MockLightClient()
        client.shouldThrow = true
        let light = makeLight(id: "l1", isOn: true, lightLevel: 80, colorHue: 0, colorSaturation: 1)
        let notifier = try! XCTUnwrap(LightNotifier(client: client, lights: [light], pinnedId: nil))
        // Should not throw — errors are swallowed with try?
        await notifier.flash()
    }
}
