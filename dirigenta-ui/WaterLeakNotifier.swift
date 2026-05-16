import Foundation
import OSLog
import UserNotifications

/// Posts a macOS notification the moment a water sensor reports
/// `waterLeakDetected == true`. Tracks last-known leak state per sensor id so
/// only the false→true transition fires; once cleared, the delivered
/// notification is removed.
@MainActor
final class WaterLeakNotifier {

    // See `MDNSResolver` for why an explicit `nonisolated deinit` is needed
    // here: AppState releases this property during its own deinit, and the
    // synthesized isolated deinit hop crashes inside libmalloc on the
    // macos-26 CI runner.
    nonisolated deinit {}

    // MARK: - Injectable side-effects (replaced in tests)

    var schedule: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(
            request,
            withCompletionHandler: nil
        )
    }
    var cancel: ([String]) -> Void = { ids in
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ids
        )
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ids
        )
    }

    // MARK: - State

    /// Last-known leak state per sensor id. Absent means we haven't seen the
    /// sensor yet — the first observation that reports `true` counts as a
    /// transition and fires the notification.
    private var lastKnownLeak: [String: Bool] = [:]

    // MARK: - Public interface

    /// Call whenever the merged device list updates. Diffs each water sensor's
    /// current leak state against the last-known value and posts/cancels a
    /// notification on the transition.
    func update(sensors: [DirigeraDevice]) {
        let enabled = UserDefaults.standard.bool(
            forKey: "settings.notifications.waterLeak"
        )
        for sensor in sensors where sensor.isWaterSensor {
            let current = sensor.attributes.waterLeakDetected ?? false
            let previous = lastKnownLeak[sensor.id]
            if current && previous != true {
                if enabled { post(for: sensor) }
            } else if !current && previous == true {
                cancel([identifier(for: sensor)])
            }
            lastKnownLeak[sensor.id] = current
        }
    }

    // MARK: - Private

    private func identifier(for sensor: DirigeraDevice) -> String {
        "water-leak:\(sensor.id)"
    }

    private func post(for sensor: DirigeraDevice) {
        let content = UNMutableNotificationContent()
        content.title = "Water leak detected"
        content.subtitle = sensor.room?.name ?? ""
        content.body = sensor.displayName
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        schedule(
            UNNotificationRequest(
                identifier: identifier(for: sensor),
                content: content,
                trigger: nil
            )
        )
        Logger.notifications.info(
            "Posted water-leak alert for \(sensor.id, privacy: .public)"
        )
    }
}
