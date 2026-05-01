import XCTest

@testable import dirigenta_ui

// MARK: - #10  LightColorPreset UserDefaults round-trip + MDNSResolver stop guard

// MARK: - LightColorPreset round-trip

final class LightColorPresetStorageTests: XCTestCase {

    private let key = "test.lightColorPreset"
    private let defaults = UserDefaults.standard

    override func tearDown() {
        defaults.removeObject(forKey: key)
        super.tearDown()
    }

    private func roundTrip(_ preset: LightColorPreset) throws -> LightColorPreset {
        let data = try JSONEncoder().encode(preset)
        defaults.set(data, forKey: key)
        let loaded = try XCTUnwrap(defaults.data(forKey: key))
        return try JSONDecoder().decode(LightColorPreset.self, from: loaded)
    }

    // MARK: All fields survive the round-trip

    func testRoundTrip_allFields() throws {
        let preset = LightColorPreset(lightLevel: 75, hue: 180.0, saturation: 0.8)
        let loaded = try roundTrip(preset)
        XCTAssertEqual(loaded.lightLevel, 75)
        XCTAssertEqual(loaded.hue!, 180.0, accuracy: 0.001)
        XCTAssertEqual(loaded.saturation!, 0.8, accuracy: 0.001)
        XCTAssertNil(loaded.colorTemperature)
    }

    func testRoundTrip_colorTemperaturePreset() throws {
        let preset = LightColorPreset(lightLevel: 60, colorTemperature: 3500)
        let loaded = try roundTrip(preset)
        XCTAssertEqual(loaded.lightLevel, 60)
        XCTAssertEqual(loaded.colorTemperature, 3500)
        XCTAssertNil(loaded.hue)
        XCTAssertNil(loaded.saturation)
    }

    func testRoundTrip_levelOnly() throws {
        let preset = LightColorPreset(lightLevel: 100)
        let loaded = try roundTrip(preset)
        XCTAssertEqual(loaded.lightLevel, 100)
        XCTAssertNil(loaded.colorTemperature)
        XCTAssertNil(loaded.hue)
        XCTAssertNil(loaded.saturation)
    }

    func testRoundTrip_nilLightLevel_preserved() throws {
        let preset = LightColorPreset(lightLevel: nil, hue: 45.0, saturation: 0.5)
        let loaded = try roundTrip(preset)
        XCTAssertNil(loaded.lightLevel)
        XCTAssertEqual(loaded.hue!, 45.0, accuracy: 0.001)
    }

    func testRoundTrip_extremeValues() throws {
        // Boundary values: level=1, hue=360, saturation=1.0, CT=6500
        let preset = LightColorPreset(
            lightLevel: 1,
            colorTemperature: 6500,
            hue: 359.99,
            saturation: 1.0
        )
        let loaded = try roundTrip(preset)
        XCTAssertEqual(loaded.lightLevel, 1)
        XCTAssertEqual(loaded.colorTemperature, 6500)
        XCTAssertEqual(loaded.hue!, 359.99, accuracy: 0.01)
        XCTAssertEqual(loaded.saturation!, 1.0, accuracy: 0.001)
    }

    func testRoundTrip_multiplePresetsAreIndependent() throws {
        // Storing a second preset under a different key must not bleed over
        let key2 = "test.lightColorPreset2"
        defer { defaults.removeObject(forKey: key2) }

        let p1 = LightColorPreset(lightLevel: 30, colorTemperature: 2700)
        let p2 = LightColorPreset(lightLevel: 90, hue: 0.0, saturation: 1.0)

        let d1 = try JSONEncoder().encode(p1)
        let d2 = try JSONEncoder().encode(p2)
        defaults.set(d1, forKey: key)
        defaults.set(d2, forKey: key2)

        let l1 = try JSONDecoder().decode(LightColorPreset.self, from: defaults.data(forKey: key)!)
        let l2 = try JSONDecoder().decode(LightColorPreset.self, from: defaults.data(forKey: key2)!)

        XCTAssertEqual(l1.colorTemperature, 2700)
        XCTAssertNil(l1.hue)
        XCTAssertEqual(l2.lightLevel, 90)
        XCTAssertNil(l2.colorTemperature)
    }
}

// MARK: - MDNSResolver stop/restart guard contract

@MainActor
final class MDNSResolverStopGuardTests: XCTestCase {

    // All resolvers below use networkingEnabled: false so the tests don't
    // touch NWBrowser / NWPathMonitor — see MDNSDiscoveryTests for the why.

    func testStopThenStart_allowsSecondStart() {
        // After stop(), hasStarted is reset so start() runs again
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
        XCTAssertFalse(resolver.isResolving)
        resolver.start()  // must not be a no-op
        XCTAssertTrue(resolver.isResolving)
        resolver.stop()
    }

    func testStop_withoutStart_doesNotCrash() {
        // stop() on a fresh resolver must be harmless
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.stop()  // should not crash or assert
        XCTAssertFalse(resolver.isResolving)
    }

    func testStop_isIdempotent() {
        // Calling stop() twice in a row must be harmless
        let resolver = MDNSResolver(networkingEnabled: false)
        resolver.start()
        resolver.stop()
        resolver.stop()  // second stop — should not crash
        XCTAssertFalse(resolver.isResolving)
    }
}
