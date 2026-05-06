import XCTest

@testable import dirigenta_ui

@MainActor
final class DemoDirigeraClientTests: XCTestCase {

    private var client: DemoDirigeraClient!

    override func setUp() {
        super.setUp()
        client = DemoDirigeraClient()
    }

    // MARK: - Fixture device set

    func testFetchAllDevices_includesEachExpectedDeviceClass() async throws {
        let devices = try await client.fetchAllDevices()

        XCTAssertTrue(
            devices.contains(where: { $0.isGateway }),
            "demo hub must surface a gateway so AppState picks up the hub name"
        )
        XCTAssertGreaterThanOrEqual(
            devices.filter(\.isLight).count,
            6,
            "demo set should include at least 6 lights so room views look populated"
        )
        XCTAssertEqual(
            devices.filter(\.isOpenCloseSensor).count,
            2,
            "demo set should expose open/close sensors so the window-notifier path runs"
        )
        XCTAssertGreaterThanOrEqual(
            devices.filter(\.isEnvironmentSensor).count,
            1,
            "demo set must include at least one env sensor for the env panel"
        )
        XCTAssertTrue(
            devices.contains(where: { $0.isGenericSwitch }),
            "demo set should expose a generic switch for the merged-switch row"
        )
    }

    func testFetchAllDevices_includesUnreachableLight() async throws {
        let devices = try await client.fetchAllDevices()
        XCTAssertTrue(
            devices.contains(where: {
                $0.isLight && $0.isReachable == false
            }),
            "demo set must include an unreachable light so the offline warning is exercised"
        )
    }

    // MARK: - State mutation

    func testSetLight_mutatesDeviceState() async throws {
        let beforeDevices = try await client.fetchAllDevices()
        let firstReachableLight = try XCTUnwrap(
            beforeDevices.first(where: {
                $0.isLight && $0.isReachable != false
            })
        )
        let toState = !(firstReachableLight.attributes.isOn ?? false)

        try await client.setLight(id: firstReachableLight.id, isOn: toState)

        let afterDevices = try await client.fetchAllDevices()
        let after = try XCTUnwrap(
            afterDevices.first { $0.id == firstReachableLight.id }
        )
        XCTAssertEqual(after.attributes.isOn, toState)
    }

    func testSetLightLevel_mutatesDeviceState() async throws {
        let devices = try await client.fetchAllDevices()
        let light = try XCTUnwrap(devices.first { $0.isLight })

        try await client.setLightLevel(id: light.id, lightLevel: 42)

        let after = try await client.fetchAllDevices()
        let updated = try XCTUnwrap(after.first { $0.id == light.id })
        XCTAssertEqual(updated.attributes.lightLevel, 42)
    }

    func testSetColor_mutatesHueAndSaturation() async throws {
        let devices = try await client.fetchAllDevices()
        let light = try XCTUnwrap(devices.first { $0.isLight })

        try await client.setColor(id: light.id, hue: 120, saturation: 0.5)

        let after = try await client.fetchAllDevices()
        let updated = try XCTUnwrap(after.first { $0.id == light.id })
        XCTAssertEqual(updated.attributes.colorHue, 120)
        XCTAssertEqual(updated.attributes.colorSaturation, 0.5)
    }

    func testSetColorTemperature_mutatesDeviceState() async throws {
        let devices = try await client.fetchAllDevices()
        let light = try XCTUnwrap(devices.first { $0.isLight })

        try await client.setColorTemperature(
            id: light.id,
            colorTemperature: 4200
        )

        let after = try await client.fetchAllDevices()
        let updated = try XCTUnwrap(after.first { $0.id == light.id })
        XCTAssertEqual(updated.attributes.colorTemperature, 4200)
    }

    func testSetLight_unknownId_doesNotCrashOrEmit() async throws {
        try await client.setLight(id: "no-such-id", isOn: true)
        // No assertion needed — the method must just no-op silently.
    }

    // MARK: - Event stream

    func testEventStream_emitsEvent_inResponseToSetLight() async throws {
        let devices = try await client.fetchAllDevices()
        let light = try XCTUnwrap(
            devices.first { $0.isLight && $0.isReachable != false }
        )

        let stream = client.eventStream()

        // Start a consumer task that pulls the first event off the stream.
        // Capturing the iterator inside the task avoids the @Sendable issue
        // of mutating an iterator across actor boundaries.
        let receiver = Task<DirigeraEvent?, Never> {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        // Give the AsyncStream's continuation-attach Task time to land on the
        // main actor before we emit the state change. Without this brief
        // delay the event can be emitted into the void.
        try await Task.sleep(for: .milliseconds(50))
        try await client.setLight(id: light.id, isOn: !light.isOn)

        // Bound the wait so a regression doesn't hang the suite.
        let timeout = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(2))
            receiver.cancel()
        }
        let event = await receiver.value
        timeout.cancel()

        let received = try XCTUnwrap(event, "expected an event within 2s")
        XCTAssertTrue(received.isDeviceStateChanged)
        XCTAssertEqual(received.data?.id, light.id)
    }
}
