import XCTest
import UserNotifications

@testable import dirigenta_ui

// MARK: - Fixtures

private func window(
    id: String,
    roomId: String? = "room1",
    roomName: String? = "Living Room",
    name: String = "Window",
    isOpen: Bool = true
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.isOpen = isOpen
    let room = roomId.flatMap { id in roomName.map { Room(id: id, name: $0) } }
    return DirigeraDevice(
        id: id,
        type: "sensor",
        deviceType: "openCloseSensor",
        room: room,
        customIcon: "placement_window",
        attributes: attrs
    )
}

private func envSensor(
    id: String,
    roomId: String = "room1",
    roomName: String? = nil,
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
        room: Room(id: roomId, name: roomName ?? roomId),
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
        UserDefaults.standard.register(defaults: [
            "settings.notifications.closeWindow": true,
            "settings.notifications.openWindow": true,
        ])
        notifier = WindowNotifier()
        notifier.minElapsed = 5 * 60
        notifier.noSensorDelay = 15 * 60
        notifier.plateauWindow = 60
        notifier.plateauThreshold = 10
        notifier.coldThreshold = 15
        notifier.humidityHighThreshold = 65
        notifier.co2HighThreshold = 1000
        notifier.co2OpenThreshold = 1200
        notifier.openWindowCooldown = 15 * 60

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

    // MARK: - Fallback timed notification always scheduled on window open

    func testWindowOpen_alwaysSchedulesFallback() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        XCTAssertEqual(timedRequests.count, 1)
        let trigger = timedRequests.first?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval, 15 * 60)
    }

    func testFallback_identifierIsWindowId() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        XCTAssertEqual(timedRequests.first?.identifier, "w1")
    }

    func testEnvSensorInDifferentRoom_fallbackStillScheduled() {
        let w = window(id: "w1", roomId: "room1")
        let sensor = envSensor(id: "e1", roomId: "room2", co2: 500)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertFalse(timedRequests.isEmpty, "Should schedule timed fallback when no sensor in same room")
    }

    // MARK: - Fallback includes room name in subtitle and readings in body

    func testFallback_subtitleIsRoomName() {
        let w = window(id: "w1", roomId: "r1", roomName: "Living Room")
        notifier.update(windows: [w], envSensors: [], now: t0)
        XCTAssertEqual(timedRequests.last?.content.subtitle, "Living Room")
    }

    func testFallback_bodyContainsWindowName() {
        let w = window(id: "w1", name: "South Window")
        notifier.update(windows: [w], envSensors: [], now: t0)
        let body = timedRequests.last?.content.body ?? ""
        XCTAssertTrue(body.contains("South Window"), "Body should contain window name; got: \(body)")
    }

    func testFallback_bodyContainsReadingsWhenAvailable() {
        let w = window(id: "w1")
        let sensor = envSensor(id: "e1", co2: 820, temperature: 21, humidity: 55)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        let body = timedRequests.last?.content.body ?? ""
        XCTAssertTrue(body.contains("°C"), "Body should contain temperature; got: \(body)")
        XCTAssertTrue(body.contains("%"), "Body should contain humidity; got: \(body)")
        XCTAssertTrue(body.contains("ppm"), "Body should contain CO2; got: \(body)")
    }

    func testFallback_bodyHasNoReadingsWhenNoneAvailable() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [], now: t0)
        let body = timedRequests.last?.content.body ?? ""
        XCTAssertFalse(body.contains("ppm"), "Body should not contain CO2 when no sensor")
        XCTAssertFalse(body.contains("°C"), "Body should not contain temperature when no sensor")
    }

    func testFallback_readingsUpdateOnEachReschedule() {
        let w = window(id: "w1")
        // First update: no readings
        notifier.update(windows: [w], envSensors: [], now: t0)
        let bodyAtT0 = timedRequests.last?.content.body ?? ""
        XCTAssertFalse(bodyAtT0.contains("ppm"))
        // Second update: readings arrive
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0 + 60)
        let bodyAtT1 = timedRequests.last?.content.body ?? ""
        XCTAssertTrue(bodyAtT1.contains("ppm"), "Body should include CO2 after readings arrive")
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
        XCTAssertEqual(timedRequests.count, 1)
    }

    // MARK: - Immediate: cold temperature

    func testColdTemperature_notifiesImmediately() {
        let w = window(id: "w1")
        let sensor = envSensor(id: "e1", temperature: 14.5)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertEqual(immediateRequests.count, 1)
        XCTAssertEqual(immediateRequests.first?.content.title, "Close window")
    }

    func testColdTemperature_bodyContainsReadings() {
        let w = window(id: "w1", name: "South Window")
        let sensor = envSensor(id: "e1", temperature: 13, humidity: 60)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        let body = immediateRequests.first?.content.body ?? ""
        XCTAssertTrue(body.contains("South Window"), "Body should contain window name; got: \(body)")
        XCTAssertTrue(body.contains("°C"), "Body should contain temperature; got: \(body)")
        XCTAssertTrue(body.contains("%"), "Body should contain humidity; got: \(body)")
    }

    func testColdTemperature_subtitleIsRoomName() {
        let w = window(id: "w1", roomId: "r1", roomName: "Bedroom")
        let sensor = envSensor(id: "e1", roomId: "r1", temperature: 12)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertEqual(immediateRequests.first?.content.subtitle, "Bedroom")
    }

    func testTemperatureAboveThreshold_doesNotNotifyImmediately() {
        let w = window(id: "w1")
        let sensor = envSensor(id: "e1", temperature: 18.0)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    // MARK: - Immediate: humidity rising above threshold

    func testHumidityHighAndRising_notifiesImmediately() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 66)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 70)], now: t0 + 60)
        XCTAssertEqual(immediateRequests.count, 1)
        XCTAssertEqual(immediateRequests.first?.content.title, "Close window")
    }

    func testHumidityNotification_bodyContainsReadings() {
        let w = window(id: "w1", name: "Bathroom Window")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", temperature: 22, humidity: 66)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", temperature: 22, humidity: 70)], now: t0 + 60)
        let body = immediateRequests.first?.content.body ?? ""
        XCTAssertTrue(body.contains("Bathroom Window"), "Body should contain window name; got: \(body)")
        XCTAssertTrue(body.contains("%"), "Body should contain humidity; got: \(body)")
        XCTAssertTrue(body.contains("°C"), "Body should contain temperature; got: \(body)")
    }

    func testHumidityHighButFalling_doesNotNotify() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 70)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 66)], now: t0 + 60)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    func testHumidityBelowThreshold_doesNotNotify() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 60)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", humidity: 62)], now: t0 + 60)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    // MARK: - 5-minute minimum

    func testBefore5min_co2Plateaued_noNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 4 * 60)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    // MARK: - CO2 still above 1000: skip

    func testCO2Above1000_skipsNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1200)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1150)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1100)], now: t0 + 5 * 60)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    // MARK: - CO2 still decreasing: skip

    func testCO2StillDecreasing_skipsNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 900)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 800)], now: t0 + 4 * 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 780)], now: t0 + 5 * 60)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    // MARK: - CO2 plateaued below 1000: notify (replaces fallback)

    func testCO2Plateaued_notifiesCanClose() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 5 * 60 + 60)
        XCTAssertEqual(immediateRequests.count, 1)
        XCTAssertEqual(immediateRequests.first?.content.title, "Window can be closed")
        XCTAssertNil(immediateRequests.first?.trigger, "Can-close notification must fire immediately")
    }

    func testCO2Notification_subtitleIsRoomName() {
        let w = window(id: "w1", roomId: "r1", roomName: "Office")
        let sensor = envSensor(id: "e1", roomId: "r1", co2: 820)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", roomId: "r1", co2: 815)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", roomId: "r1", co2: 815)], now: t0 + 5 * 60 + 60)
        XCTAssertEqual(immediateRequests.first?.content.subtitle, "Office")
    }

    func testCO2Notification_bodyContainsReadings() {
        let w = window(id: "w1", name: "South Window")
        let sensor = envSensor(id: "e1", co2: 820, temperature: 21, humidity: 55)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815, temperature: 21, humidity: 55)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815, temperature: 21, humidity: 55)], now: t0 + 5 * 60 + 60)
        let body = immediateRequests.first?.content.body ?? ""
        XCTAssertTrue(body.contains("South Window"), "Body should contain window name; got: \(body)")
        XCTAssertTrue(body.contains("°C"), "Body should contain temperature; got: \(body)")
        XCTAssertTrue(body.contains("%"), "Body should contain humidity; got: \(body)")
        XCTAssertTrue(body.contains("ppm"), "Body should contain CO2; got: \(body)")
    }

    // MARK: - No double notification

    func testAlreadyNotified_doesNotNotifyAgain() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 5 * 60 + 60)
        let countAfterFirst = postedRequests.count
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 10 * 60)
        XCTAssertEqual(postedRequests.count, countAfterFirst)
    }

    // MARK: - Sensor has no CO2: fall back to timed notification

    func testSensorWithNoCO2_fallsBackToTimer() {
        let w = window(id: "w1")
        let sensor = envSensor(id: "e1", temperature: 21.0, humidity: 50.0)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        notifier.update(windows: [w], envSensors: [sensor], now: t0 + 6 * 60)
        XCTAssertTrue(immediateRequests.isEmpty, "Should not post without CO2 data; fallback timer handles it")
        XCTAssertFalse(timedRequests.isEmpty)
    }

    // MARK: - Sensor goes offline: evaluate stops after noSensorDelay

    func testSensorGoesOffline_noDoubleNotificationAfterDelay() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 1100)], now: t0)
        notifier.update(windows: [w], envSensors: [], now: t0 + 8 * 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 700)], now: t0 + 16 * 60)
        XCTAssertTrue(immediateRequests.isEmpty, "Evaluate must not fire after noSensorDelay has passed")
    }

    // MARK: - Multiple sensors: CO2 is averaged

    func testMultipleSensors_averagesCO2ForNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [
            envSensor(id: "e1", co2: 1050),
            envSensor(id: "e2", co2: 750)
        ], now: t0)
        notifier.update(windows: [w], envSensors: [
            envSensor(id: "e1", co2: 1045),
            envSensor(id: "e2", co2: 745)
        ], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [
            envSensor(id: "e1", co2: 1045),
            envSensor(id: "e2", co2: 745)
        ], now: t0 + 5 * 60 + 60)
        XCTAssertEqual(immediateRequests.count, 1)
        XCTAssertEqual(immediateRequests.first?.content.title, "Window can be closed")
    }

    func testMultipleSensors_highAverageCO2_skipsNotification() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [
            envSensor(id: "e1", co2: 1200),
            envSensor(id: "e2", co2: 1100)
        ], now: t0)
        notifier.update(windows: [w], envSensors: [
            envSensor(id: "e1", co2: 1200),
            envSensor(id: "e2", co2: 1100)
        ], now: t0 + 5 * 60 + 60)
        XCTAssertTrue(immediateRequests.isEmpty)
    }

    // MARK: - CO2 notification replaces fallback (same identifier)

    func testCO2Notification_hasSameIdentifierAsFallback() {
        let w = window(id: "w1")
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 820)], now: t0)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 60)
        notifier.update(windows: [w], envSensors: [envSensor(id: "e1", co2: 815)], now: t0 + 5 * 60 + 60)
        XCTAssertTrue(postedRequests.map(\.identifier).allSatisfy { $0 == "w1" })
    }

    // MARK: - Open window: basic triggering

    func testHighCO2_noOpenWindow_hasWindowSensor_notifiesOpenWindow() {
        let w = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1300)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertEqual(openWindowRequests.count, 1)
        XCTAssertEqual(openWindowRequests.first?.content.title, "Open a window")
    }

    func testHighCO2_windowAlreadyOpen_noOpenWindowNotification() {
        let w = window(id: "w1", isOpen: true)
        let sensor = envSensor(id: "e1", co2: 1300)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertTrue(openWindowRequests.isEmpty)
    }

    func testHighCO2_noWindowSensorInRoom_noOpenWindowNotification() {
        let sensor = envSensor(id: "e1", co2: 1300)
        notifier.update(windows: [], envSensors: [sensor], now: t0)
        XCTAssertTrue(openWindowRequests.isEmpty)
    }

    func testCO2BelowOpenThreshold_noOpenWindowNotification() {
        let w = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1100) // below 1200
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertTrue(openWindowRequests.isEmpty)
    }

    func testWindowSensorInDifferentRoom_noOpenWindowNotification() {
        let w = window(id: "w1", roomId: "room2", isOpen: false)
        let sensor = envSensor(id: "e1", roomId: "room1", co2: 1300)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertTrue(openWindowRequests.isEmpty)
    }

    // MARK: - Open window: notification content

    func testOpenWindowNotification_subtitleIsRoomName() {
        let w = window(id: "w1", roomId: "r1", roomName: "Kitchen", isOpen: false)
        let sensor = envSensor(id: "e1", roomId: "r1", roomName: "Kitchen", co2: 1300)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        XCTAssertEqual(openWindowRequests.first?.content.subtitle, "Kitchen")
    }

    func testOpenWindowNotification_bodyContainsSensorName() {
        let w = window(id: "w1", isOpen: false)
        var attrs = DirigeraDevice.Attributes()
        attrs.customName = "CO2 Sensor"
        attrs.currentCO2 = 1300
        let sensor = DirigeraDevice(
            id: "e1", type: "sensor", deviceType: "environmentSensor",
            room: Room(id: "room1", name: "room1"), attributes: attrs
        )
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        let body = openWindowRequests.first?.content.body ?? ""
        XCTAssertTrue(body.contains("CO2 Sensor"), "Body should contain sensor name; got: \(body)")
    }

    func testOpenWindowNotification_bodyContainsReadings() {
        let w = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1350, temperature: 22, humidity: 58)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        let body = openWindowRequests.first?.content.body ?? ""
        XCTAssertTrue(body.contains("ppm"), "Body should contain CO2 reading; got: \(body)")
        XCTAssertTrue(body.contains("°C"), "Body should contain temperature; got: \(body)")
        XCTAssertTrue(body.contains("%"), "Body should contain humidity; got: \(body)")
    }

    // MARK: - Open window: cooldown

    func testOpenWindowNotification_respectsCooldown() {
        let w = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1300)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        notifier.update(windows: [w], envSensors: [sensor], now: t0 + 5 * 60) // within cooldown
        XCTAssertEqual(openWindowRequests.count, 1, "Should not repeat within the cooldown window")
    }

    func testOpenWindowNotification_firesAgainAfterCooldown() {
        let w = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1300)
        notifier.update(windows: [w], envSensors: [sensor], now: t0)
        notifier.update(windows: [w], envSensors: [sensor], now: t0 + 16 * 60) // past cooldown
        XCTAssertEqual(openWindowRequests.count, 2, "Should fire again after cooldown expires")
    }

    // MARK: - Open window: cancelled when window opens

    func testWindowOpening_cancelsPendingOpenWindowNotification() {
        let closed = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1300)
        notifier.update(windows: [closed], envSensors: [sensor], now: t0)
        // User opens the window
        let open = window(id: "w1", isOpen: true)
        notifier.update(windows: [open], envSensors: [sensor], now: t0 + 60)
        XCTAssertTrue(cancelled.flatMap { $0 }.contains("open-window:room1"))
    }

    func testWindowOpening_resetsCooldown_allowsImmediateRealert() {
        let closed = window(id: "w1", isOpen: false)
        let sensor = envSensor(id: "e1", co2: 1300)
        // First alert fires
        notifier.update(windows: [closed], envSensors: [sensor], now: t0)
        // Window opens (clears cooldown)
        let open = window(id: "w1", isOpen: true)
        notifier.update(windows: [open], envSensors: [sensor], now: t0 + 60)
        // Window closes again, CO2 still high — should alert immediately without waiting for cooldown
        notifier.update(windows: [closed], envSensors: [sensor], now: t0 + 120)
        XCTAssertEqual(openWindowRequests.count, 2,
                       "Should re-alert immediately after cooldown reset by window opening")
    }

    // MARK: - Helpers

    private var immediateRequests: [UNNotificationRequest] {
        postedRequests.filter { $0.trigger == nil && !$0.identifier.hasPrefix("open-window:") }
    }

    private var timedRequests: [UNNotificationRequest] {
        postedRequests.filter { $0.trigger is UNTimeIntervalNotificationTrigger }
    }

    private var openWindowRequests: [UNNotificationRequest] {
        postedRequests.filter { $0.identifier.hasPrefix("open-window:") }
    }
}
