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
    var noSensorDelay: TimeInterval = 15 * 60    // fallback when no CO2 readings arrive
    var historyWindow: TimeInterval = 10 * 60    // how long to keep readings
    var plateauWindow: TimeInterval = 60         // trend-comparison window
    var plateauThreshold: Double = 10            // ppm change still counted as decreasing
    var coldThreshold: Double = 15              // °C below which we notify immediately
    var humidityHighThreshold: Double = 65      // % above which rising humidity is urgent
    var co2HighThreshold: Double = 1000         // ppm above which still ventilating
    var co2OpenThreshold: Double = 1200         // ppm above which "open a window" is suggested
    var openWindowCooldown: TimeInterval = 15 * 60  // minimum interval between "open window" alerts per room

    // MARK: - Injectable side-effects (replaced in tests)

    var schedule: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    var cancel: ([String]) -> Void = { ids in
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - State

    private var openedAt: [String: Date] = [:]                    // windowId → time window opened
    private var notified: Set<String> = []                        // windows already notified this open period
    private var history: [String: [EnvReading]] = [:]             // roomId → rolling reading buffer
    private var lastOpenWindowNotification: [String: Date] = [:]  // roomId → last "open a window" alert time

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

        // Track newly opened windows. Prefer the sensor's lastSeen timestamp so a window
        // already open at app start is treated as having been open since then, not since launch.
        // When a window just opens, cancel any pending "open a window" alert for its room and
        // clear the cooldown so a future CO2 spike after it closes can re-trigger immediately.
        for window in openWindows where openedAt[window.id] == nil {
            let openTime = window.lastSeenDate.map { min($0, now) } ?? now
            openedAt[window.id] = openTime
            if let roomId = window.room?.id {
                cancel(["open-window:\(roomId)"])
                lastOpenWindowNotification.removeValue(forKey: roomId)
            }
        }

        if UserDefaults.standard.bool(forKey: "settings.notifications.closeWindow") {
            // Reschedule the timed fallback on every update for all pending windows, baking in
            // the latest readings so the notification shows current sensor state when it fires.
            // If an env-sensor reading arrives in time, evaluate() posts an immediate notification
            // with the same identifier, replacing the pending timed one.
            for window in openWindows where !notified.contains(window.id) {
                guard let openTime = openedAt[window.id] else { continue }
                guard now.timeIntervalSince(openTime) < noSensorDelay else { continue }
                let readings = roomReadings(for: window)
                scheduleFallbackNotification(for: window, openedAt: openTime, readings: readings, now: now)
            }

            // Evaluate open windows that haven't been notified yet.
            for window in openWindows where !notified.contains(window.id) {
                evaluate(window: window, now: now)
            }
        }

        // Check whether any room needs a window opened (high CO2, no open window).
        checkOpenWindowNeeded(windows: windows, envSensors: envSensors, now: now)
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

    private func evaluate(window: DirigeraDevice, now: Date) {
        guard let openTime = openedAt[window.id] else { return }

        let readings = roomReadings(for: window)

        // Average recent values across all sensors and readings to reduce noise
        let latestTemp = recentAverage(in: readings, keyPath: \.temperature, now: now)
        let latestHumidity = recentAverage(in: readings, keyPath: \.humidity, now: now)

        // Immediate: temperature falling below threshold
        if let temp = latestTemp, temp < coldThreshold {
            post(for: window, title: "Close window", reason: "getting cold",
                 readings: readings, now: now)
            return
        }

        // Immediate: humidity high and actively rising
        if let humidity = latestHumidity, humidity > humidityHighThreshold {
            let olderHumidity = olderAverage(in: readings, keyPath: \.humidity, now: now)
            if let old = olderHumidity, humidity > old {
                post(for: window, title: "Close window", reason: "humidity rising",
                     readings: readings, now: now)
                return
            }
        }

        // Wait for minimum elapsed time before "can close" check
        guard now.timeIntervalSince(openTime) >= minElapsed else { return }

        // After noSensorDelay the fallback notification has already fired; stop evaluating
        // to avoid a second notification if a sensor comes back online later.
        guard now.timeIntervalSince(openTime) < noSensorDelay else { return }

        // Average recent CO2 across all sensors in the room.
        // If no CO2 readings have arrived (sensor absent, offline, or measures only
        // temperature/humidity), return and let the timed fallback handle notification.
        guard let co2 = recentAverage(in: readings, keyPath: \.co2, now: now) else { return }

        if co2 > co2HighThreshold { return }
        let olderCO2 = olderAverage(in: readings, keyPath: \.co2, now: now)
        if let old = olderCO2, co2 < old - plateauThreshold { return }

        post(for: window, title: "Window can be closed", reason: "air quality good",
             readings: readings, now: now)
    }

    private func roomReadings(for window: DirigeraDevice) -> [EnvReading] {
        guard let roomId = window.room?.id else { return [] }
        return history[roomId] ?? []
    }

    /// Average of non-nil values within the last `plateauWindow` seconds (exclusive boundary
    /// so this window does not overlap with olderAverage).
    private func recentAverage(
        in readings: [EnvReading],
        keyPath: KeyPath<EnvReading, Double?>,
        now: Date
    ) -> Double? {
        let cutoff = now - plateauWindow
        let values = readings.filter { $0.timestamp > cutoff }.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Average of non-nil values centred on `plateauWindow` seconds ago (±50 % tolerance).
    private func olderAverage(
        in readings: [EnvReading],
        keyPath: KeyPath<EnvReading, Double?>,
        now: Date
    ) -> Double? {
        let target = now - plateauWindow
        let tolerance = plateauWindow / 2
        let values = readings
            .filter { abs($0.timestamp.timeIntervalSince(target)) <= tolerance }
            .compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Compact summary of available sensor readings, e.g. "20°C · 63% · 820 ppm".
    private func readingsSummary(readings: [EnvReading], now: Date) -> String {
        var parts: [String] = []
        if let temp = recentAverage(in: readings, keyPath: \.temperature, now: now) {
            parts.append(String(format: "%.0f°C", temp))
        }
        if let humidity = recentAverage(in: readings, keyPath: \.humidity, now: now) {
            parts.append(String(format: "%.0f%%", humidity))
        }
        if let co2 = recentAverage(in: readings, keyPath: \.co2, now: now) {
            parts.append(String(format: "%.0f ppm", co2))
        }
        return parts.joined(separator: " · ")
    }

    private func scheduleFallbackNotification(
        for window: DirigeraDevice,
        openedAt: Date,
        readings: [EnvReading],
        now: Date
    ) {
        let remaining = noSensorDelay - now.timeIntervalSince(openedAt)
        let content = UNMutableNotificationContent()
        content.title = "Close window?"
        content.subtitle = window.room?.name ?? ""
        let minutes = Int(noSensorDelay / 60)
        let baseBody = "\(window.displayName) has been open for \(minutes) minutes"
        let summary = readingsSummary(readings: readings, now: now)
        content.body = summary.isEmpty ? baseBody : baseBody + " · " + summary
        content.sound = .default
        let trigger: UNNotificationTrigger? = remaining > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
            : nil
        schedule(UNNotificationRequest(identifier: window.id, content: content, trigger: trigger))
        Logger.notifications.info(
            "Scheduled fallback notification for \(window.id, privacy: .public)"
        )
    }

    private func checkOpenWindowNeeded(windows: [DirigeraDevice], envSensors: [DirigeraDevice], now: Date) {
        guard UserDefaults.standard.bool(forKey: "settings.notifications.openWindow") else { return }
        // Index all window sensors and env sensors by room
        var windowsByRoom: [String: [DirigeraDevice]] = [:]
        for w in windows where w.isWindowSensor {
            guard let roomId = w.room?.id else { continue }
            windowsByRoom[roomId, default: []].append(w)
        }
        var sensorsByRoom: [String: [DirigeraDevice]] = [:]
        for s in envSensors {
            guard let roomId = s.room?.id else { continue }
            sensorsByRoom[roomId, default: []].append(s)
        }

        for (roomId, roomSensors) in sensorsByRoom {
            // Room must have at least one window sensor
            guard let roomWindows = windowsByRoom[roomId], !roomWindows.isEmpty else { continue }
            // Skip if a window is already open
            if roomWindows.contains(where: { $0.isOpen }) { continue }
            // CO2 must be above the open threshold
            let readings = history[roomId] ?? []
            guard let co2 = recentAverage(in: readings, keyPath: \.co2, now: now),
                  co2 > co2OpenThreshold else { continue }
            // Enforce per-room cooldown
            if let last = lastOpenWindowNotification[roomId],
               now.timeIntervalSince(last) < openWindowCooldown { continue }

            let roomName = roomSensors.first?.room?.name ?? roomId
            let sensorNames = roomSensors.map(\.displayName).joined(separator: ", ")
            let summary = readingsSummary(readings: readings, now: now)
            let content = UNMutableNotificationContent()
            content.title = "Open a window"
            content.subtitle = roomName
            content.body = summary.isEmpty ? sensorNames : sensorNames + " · " + summary
            content.sound = .default
            schedule(UNNotificationRequest(
                identifier: "open-window:\(roomId)",
                content: content,
                trigger: nil
            ))
            lastOpenWindowNotification[roomId] = now
            Logger.notifications.info(
                "Posted 'Open a window' for room \(roomId, privacy: .public)"
            )
        }
    }

    private func post(
        for window: DirigeraDevice,
        title: String,
        reason: String,
        readings: [EnvReading],
        now: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = window.room?.name ?? ""
        let baseBody = "\(window.displayName) \(reason)"
        let summary = readingsSummary(readings: readings, now: now)
        content.body = summary.isEmpty ? baseBody : baseBody + " · " + summary
        content.sound = .default
        schedule(UNNotificationRequest(identifier: window.id, content: content, trigger: nil))
        notified.insert(window.id)
        Logger.notifications.info(
            "Posted '\(title, privacy: .public)' for \(window.id, privacy: .public)"
        )
    }
}
