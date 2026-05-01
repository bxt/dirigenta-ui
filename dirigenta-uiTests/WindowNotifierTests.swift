import XCTest
import UserNotifications

@testable import dirigenta_ui

// MARK: - Fixtures

private func window(
    id: String,
    roomId: String? = "room1",
    name: String = "Window",
    isOpen: Bool = true
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.isOpen = isOpen
    return DirigeraDevice(
        id: id,
        type: "sensor",
        deviceType: "openCloseSensor",
        room: roomId.map { Room(id: $0, name: $0) },
        customIcon: "placement_window",
        attributes: attrs
    )
}

private func envSensor(
    id: String,
    roomId: String = "room1",
    co2: Double? = nil,
    temperature: Double? = nil,
    humidity: Double? = nil
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = "Sensor"
    attrs.currentCO2 = co2
    attrs.currentTemperature = temperature
    attrs.currentRH = humidity
    return DirigeraDevice(
        id: id,
        type: "sensor",
        deviceType: "environmentSensor",
        room: Room(id: roomId, name: roomId),
        attributes: attrs
    )
}

private func nonWindowSensor(id: String) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = "Door"
    attrs.isOpen = true
    return DirigeraDevice(id: id, type: "sensor", deviceType: "openCloseSensor", attributes: attrs)
}

// MARK: - WindowNotifierTests

@MainActor
final class WindowNotifierTests: XCTestCase {

    private var notifier: WindowNotifier!
    private var postedRequests: [UNNotificationRequest] = []
    private var cancelled: [[String]] = []

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    override func setUp() {
        super.setUp()
        notifier = WindowNotifier()
        notifier.minElapsed = 5 * 60
        notifier.noSensorDelay = 15 * 60
        notifier.plateauWindow = 60
        notifier.plateauThreshold = 10
        notifier.coldThreshold = 15
        notifier.humidityHighThreshold = 65
        notifier.co2HighThreshold = 1000

        postedRequests = []
        cancelled = []
        notifier.schedule = { [weak self] req in self?.postedRequests.append(req) }
        notifier.cancel = { [weak self] ids in self?.cancelled.append(ids) }
    }

    // MARK: - Non-window sensor is ignored

    func testNonWindowSensor_neverNotifies() {
        let door = nonWindowSensor(id: "d1")
        notifier.update(windows: [door], envSensors: [], now: t0)
        notifier.update(windows: [door], envSensors: [], now: t0 + 20 * 60)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    // MARK: - No env sensor in same room → 15-min timed notification

    func testNoEnvSensor_schedulesTimedNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        XCTAssertEqual(postedRequests.count, 1)
        let trigger = postedRequests.first?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval, 15 * 60)
    }

    func testNoEnvSensor_identifierIsWindowId() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        XCTAssertEqual(postedRequests.first?.identifier, "w1")
    }

    func testEnvSensorInDifferentRoom_treatedAsNoSensor() {
        let w = window(id: "w1", roomId: "room1")
        let sensor = envSensor(id: "e1", roomId: "room2", co2: 500)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        let trigger = postedRequests.first?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertNotNil(trigger, "Should schedule timed notification when no sensor in same room")
    }

    // MARK: - Window closing cancels notification

    func testWindowCloses_cancelsNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        notifier.update(windows: [window(id: "w1", isOpen: false)], envSensors: [], now: t0 + 60)
        XCTAssertTrue(cancelled.flatMap { $0 }.contains("w1"))
    }

    func testWindowReopens_schedulesNewNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        notifier.update(windows: [], envSensors: [], now: t0 + 60)     // closed
        postedRequests.removeAll()
        notifier.update(windows: [w], envSensors: [], now: t0 + 120)   // reopened
        XCTAssertEqual(postedRequests.count, 1)
    }

    // MARK: - Immediate: cold temperature

    func testColdTemperature_notifiesImmediately() {
        let w = window(id: "w1")
        let sensor = envSensor(id: "e1", temperature: 14.5)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertEqual(postedRequests.count, 1)
        XCTAssertEqual(postedRequests.first?.content.title, "Close window")
    }

    func testTemperatureAboveThreshold_doesNotNotifyImmediately() {
        let w = window(id: "w1")
        let sensor = envSensor(id: "e1", temperature: 18.0)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    // MARK: - Immediate: humidity rising above threshold

    func testHumidityHighAndRising_notifiesImmediately() {
        let w = window(id: "w1")
        // First reading at t0: humidity 66 %
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 66)], now: t0)
        // One minute later: humidity 70 % (rising)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 70)], now: t0 + 60)
        XCTAssertEqual(postedRequests.count, 1)
        XCTAssertEqual(postedRequests.first?.content.title, "Close window")
    }

    func testHumidityHighButFalling_doesNotNotify() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 70)], now: t0)
        // Falling: 70 → 66
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 66)], now: t0 + 60)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    func testHumidityBelowThreshold_doesNotNotify() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 60)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 62)], now: t0 + 60)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    // MARK: - 5-minute minimum

    func testBefore5min_co2Plateaued_noNotification() {
        let w = window(id: "w1")
        // Record two readings 1 min apart showing plateau (< 10 ppm change)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        // Check at 4 minutes — below minElapsed
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 4 * 60)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    // MARK: - CO2 still above 1000: skip

    func testCO2Above1000_skipsNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1200)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1150)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1100)], now: t0 + 5 * 60)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    // MARK: - CO2 still decreasing: skip

    func testCO2StillDecreasing_skipsNotification() {
        let w = window(id: "w1")
        // t=0: CO2=900
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 900)], now: t0)
        // t=4min: CO2=800 (reference ~1 min ago will be the t=0 entry, change = -100 > threshold)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 800)], now: t0 + 4 * 60)
        // t=5min: CO2=780, oldest reading ~60s ago ≈ t=4min entry (800), change=-20 > threshold
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 780)], now: t0 + 5 * 60)
        XCTAssertTrue(postedRequests.isEmpty)
    }

    // MARK: - CO2 plateaued below 1000: notify

    func testCO2Plateaued_notifiesCanClose() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        // At 5+ min, reading ~1 min ago is 815, current is 815 (change = 0, below threshold)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 5 * 60 + 60)
        XCTAssertEqual(postedRequests.count, 1)
        XCTAssertEqual(postedRequests.first?.content.title, "Window can be closed")
        XCTAssertNil(postedRequests.first?.trigger, "Can-close notification must fire immediately")
    }

    // MARK: - No double notification

    func testAlreadyNotified_doesNotNotifyAgain() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 5 * 60 + 60)
        let countAfterFirst = postedRequests.count
        // Additional updates should not fire more notifications
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 10 * 60)
        XCTAssertEqual(postedRequests.count, countAfterFirst)
    }
}
