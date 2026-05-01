import Foundation
import UserNotifications
import OSLog

// MARK: - EnvReading

struct EnvReading {
    let timestamp: Date
    let co2: Double?
    let temperature: Double?
    let humidity: Double?
}

// MARK: - WindowNotifier

/// Watches open/close sensors marked as windows and posts macOS notifications
/// when the window can be closed, based on air quality from env sensors in the
/// same room.
@MainActor
final class WindowNotifier {

    // MARK: - Thresholds (var so tests can override)

    var minElapsed: TimeInterval = 5 * 60        // wait before "can close" check
    var noSensorDelay: TimeInterval = 15 * 60    // fallback when no env sensor
    var historyWindow: TimeInterval = 10 * 60    // how long to keep readings
    var plateauWindow: TimeInterval = 60         // trend-comparison window
    var plateauThreshold: Double = 10            // ppm change still counted as decreasing
    var coldThreshold: Double = 15              // °C below which we notify immediately
    var humidityHighThreshold: Double = 65      // % above which rising humidity is urgent
    var co2HighThreshold: Double = 1000         // ppm above which still ventilating

    // MARK: - Injectable side-effects (replaced in tests)

    var schedule: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    var cancel: ([String]) -> Void = { ids in
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - State

    private var openedAt: [String: Date] = [:]      // windowId → time window opened
    private var notified: Set<String> = []           // windows already notified this open period
    private var history: [String: [EnvReading]] = [:] // roomId → rolling reading buffer

    // MARK: - Public interface

    /// Call whenever sensors or env-sensor readings change.
    func update(windows: [DirigeraDevice], envSensors: [DirigeraDevice], now: Date) {
        recordReadings(from: envSensors, now: now)

        let openWindows = windows.filter { $0.isWindowSensor && $0.isOpen }
        let openIds = Set(openWindows.map(\.id))

        // Cancel notifications for windows that just closed
        let justClosed = Set(openedAt.keys).subtracting(openIds)
        if !justClosed.isEmpty {
            cancel(Array(justClosed))
            for id in justClosed {
                openedAt.removeValue(forKey: id)
                notified.remove(id)
            }
        }

        // Track newly opened windows; schedule fallback for those without an env sensor.
        // Prefer the sensor's lastSeen timestamp so a window already open at app start
        // is treated as having been open since then, not since launch.
        for window in openWindows where openedAt[window.id] == nil {
            let openTime = window.lastSeenDate.map { min($0, now) } ?? now
            openedAt[window.id] = openTime
            if !hasEnvSensor(for: window, in: envSensors) {
                scheduleNoSensorNotification(for: window, openedAt: openTime, now: now)
            }
        }

        // Evaluate windows that have an env sensor and haven't been notified yet
        for window in openWindows where !notified.contains(window.id) {
            evaluate(window: window, envSensors: envSensors, now: now)
        }
    }

    // MARK: - Private

    private func recordReadings(from sensors: [DirigeraDevice], now: Date) {
        let cutoff = now - historyWindow
        for sensor in sensors {
            guard let roomId = sensor.room?.id else { continue }
            let reading = EnvReading(
                timestamp: now,
                co2: sensor.attributes.currentCO2,
                temperature: sensor.attributes.currentTemperature,
                humidity: sensor.attributes.currentRH
            )
            var entries = history[roomId, default: []]
            entries.append(reading)
            history[roomId] = entries.filter { $0.timestamp >= cutoff }
        }
    }

    private func evaluate(window: DirigeraDevice, envSensors: [DirigeraDevice], now: Date) {
        guard hasEnvSensor(for: window, in: envSensors),
              let openTime = openedAt[window.id]
        else { return }

        let readings = roomReadings(for: window)
        let latestTemp = readings.last?.temperature
        let latestHumidity = readings.last?.humidity
        let latestCO2 = readings.last?.co2

        // Immediate: temperature falling below threshold
        if let temp = latestTemp, temp < coldThreshold {
            post(for: window,
                 title: "Close window",
                 body: String(format: "Temperature is %.0f°C — getting cold", temp))
            return
        }

        // Immediate: humidity high and actively rising
        if let humidity = latestHumidity, humidity > humidityHighThreshold {
            let olderHumidity = closestReading(in: readings, ago: plateauWindow, now: now)?.humidity
            if let old = olderHumidity, humidity > old {
                post(for: window,
                     title: "Close window",
                     body: String(format: "Humidity rising (%.0f%%)", humidity))
                return
            }
        }

        // Wait for minimum elapsed time before "can close" check
        guard now.timeIntervalSince(openTime) >= minElapsed else { return }

        // CO2-based skip conditions
        if let co2 = latestCO2 {
            if co2 > co2HighThreshold { return }
            let olderCO2 = closestReading(in: readings, ago: plateauWindow, now: now)?.co2
            if let old = olderCO2, co2 < old - plateauThreshold { return }
        }

        post(for: window,
             title: "Window can be closed",
             body: "Air quality is good — \(window.displayName)")
    }

    private func hasEnvSensor(for window: DirigeraDevice, in sensors: [DirigeraDevice]) -> Bool {
        guard let roomId = window.room?.id else { return false }
        return sensors.contains { $0.room?.id == roomId }
    }

    private func roomReadings(for window: DirigeraDevice) -> [EnvReading] {
        guard let roomId = window.room?.id else { return [] }
        return history[roomId] ?? []
    }

    private func closestReading(in readings: [EnvReading], ago seconds: TimeInterval, now: Date) -> EnvReading? {
        let target = now - seconds
        return readings.min(by: {
            abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target))
        })
    }

    private func scheduleNoSensorNotification(for window: DirigeraDevice, openedAt: Date, now: Date) {
        let remaining = noSensorDelay - now.timeIntervalSince(openedAt)
        let content = UNMutableNotificationContent()
        content.title = "Close window?"
        content.body = "\(window.displayName) has been open for 15 minutes"
        content.sound = .default
        let trigger: UNNotificationTrigger? = remaining > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
            : nil
        schedule(UNNotificationRequest(identifier: window.id, content: content, trigger: trigger))
        notified.insert(window.id)
        Logger.notifications.info(
            "Scheduled 15-min notification for \(window.id, privacy: .public)"
        )
    }

    private func post(for window: DirigeraDevice, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        schedule(UNNotificationRequest(identifier: window.id, content: content, trigger: nil))
        notified.insert(window.id)
        Logger.notifications.info(
            "Posted '\(title, privacy: .public)' for \(window.id, privacy: .public)"
        )
    }
}
