import XCTest
import UserNotifications

@testable import dirigenta_ui

// MARK: - Fixtures

private func waterSensor(
    id: String,
    leak: Bool? = false,
    roomName: String? = "Kitchen",
    name: String = "Under Sink"
) -> DirigeraDevice {
    var attrs = DirigeraDevice.Attributes()
    attrs.customName = name
    attrs.waterLeakDetected = leak
    let room = roomName.map { Room(id: "r1", name: $0) }
    return DirigeraDevice(
        id: id,
        type: "sensor",
        deviceType: "waterSensor",
        room: room,
        attributes: attrs
    )
}

// MARK: - WaterLeakNotifierTests

@MainActor
final class WaterLeakNotifierTests: XCTestCase {

    private var notifier: WaterLeakNotifier!
    private var postedRequests: [UNNotificationRequest] = []
    private var cancelled: [[String]] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(
            true,
            forKey: "settings.notifications.waterLeak"
        )
        notifier = WaterLeakNotifier()
        notifier.schedule = { [weak self] in self?.postedRequests.append($0) }
        notifier.cancel = { [weak self] in self?.cancelled.append($0) }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(
            forKey: "settings.notifications.waterLeak"
        )
        notifier = nil
        postedRequests = []
        cancelled = []
        super.tearDown()
    }

    func testFirstUpdate_dry_doesNotNotify() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: false)])
        XCTAssertTrue(postedRequests.isEmpty)
    }

    func testFirstUpdate_alreadyLeaking_notifiesImmediately() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        XCTAssertEqual(postedRequests.count, 1)
        XCTAssertEqual(postedRequests.first?.identifier, "water-leak:w1")
        XCTAssertEqual(
            postedRequests.first?.content.title,
            "Water leak detected"
        )
        XCTAssertEqual(postedRequests.first?.content.subtitle, "Kitchen")
        XCTAssertEqual(postedRequests.first?.content.body, "Under Sink")
    }

    func testTransitionDryToLeak_notifies() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: false)])
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        XCTAssertEqual(postedRequests.count, 1)
    }

    func testLeakStaysTrue_doesNotNotifyAgain() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        XCTAssertEqual(postedRequests.count, 1)  // only the first transition
    }

    func testTransitionLeakToDry_cancelsNotification() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        notifier.update(sensors: [waterSensor(id: "w1", leak: false)])
        XCTAssertEqual(cancelled, [["water-leak:w1"]])
    }

    func testLeakClearedThenReturns_notifiesAgain() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        notifier.update(sensors: [waterSensor(id: "w1", leak: false)])
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        XCTAssertEqual(postedRequests.count, 2)
    }

    func testNilLeakAttribute_treatedAsDry() {
        notifier.update(sensors: [waterSensor(id: "w1", leak: nil)])
        XCTAssertTrue(postedRequests.isEmpty)
    }

    func testNotificationsDisabled_doesNotNotify() {
        UserDefaults.standard.set(
            false,
            forKey: "settings.notifications.waterLeak"
        )
        notifier.update(sensors: [waterSensor(id: "w1", leak: true)])
        XCTAssertTrue(postedRequests.isEmpty)
        // State is still tracked, so clearing the (unsent) alert still cancels.
        notifier.update(sensors: [waterSensor(id: "w1", leak: false)])
        XCTAssertEqual(cancelled, [["water-leak:w1"]])
    }

    func testNonWaterSensorsIgnored() {
        var attrs = DirigeraDevice.Attributes()
        attrs.isOpen = true
        let door = DirigeraDevice(
            id: "d1", type: "sensor", deviceType: "openCloseSensor",
            attributes: attrs
        )
        notifier.update(sensors: [door])
        XCTAssertTrue(postedRequests.isEmpty)
    }

    func testMultipleSensors_eachTrackedIndependently() {
        notifier.update(sensors: [
            waterSensor(id: "w1", leak: true),
            waterSensor(id: "w2", leak: false),
        ])
        XCTAssertEqual(postedRequests.count, 1)
        XCTAssertEqual(postedRequests.first?.identifier, "water-leak:w1")

        notifier.update(sensors: [
            waterSensor(id: "w1", leak: true),
            waterSensor(id: "w2", leak: true),
        ])
        XCTAssertEqual(postedRequests.count, 2)
        XCTAssertEqual(postedRequests.last?.identifier, "water-leak:w2")
    }
}
