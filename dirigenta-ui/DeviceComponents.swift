import SwiftUI

// MARK: - Row components

// Battery + optional room name footer used by sensor rows.
// Battery text turns orange when below 10%.
private struct SensorFooter: View {
    let battery: Int?
    let room: String?

    var body: some View {
        if battery != nil || room != nil {
            HStack(spacing: 0) {
                if let battery {
                    Text("\(battery)% battery")
                        .foregroundStyle(battery < 10 ? Color.orange : Color.secondary)
                    if room != nil {
                        Text(" · ").foregroundStyle(.secondary)
                    }
                }
                if let room {
                    Text(room).foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
    }
}

// Attributed-string display for a list of env sensor readings.
// isHeadline: true → body-sized primary text, for DisclosureGroup summary
// rows; false (default) → caption2 secondary, for inside detail rows.
struct EnvReadingsLine: View {
    let readings: [DirigeraDevice.Reading]
    var isHeadline: Bool = false

    private var attributed: AttributedString {
        readings.enumerated().reduce(into: AttributedString()) { str, item in
            let (i, r) = item
            if i > 0 { str += AttributedString(" · ") }
            var part = AttributedString(r.text)
            if r.outOfRange { part.foregroundColor = .orange }
            str += part
        }
    }

    var body: some View {
        if isHeadline {
            Text(attributed).foregroundStyle(.primary)
        } else {
            Text(attributed).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// Individual env-sensor row. showRoom: true appends the room name next to
// the battery level; used in the devices tab where rows aren't grouped.
struct EnvSensorRow: View {
    let sensor: DirigeraDevice
    var showRoom: Bool = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.displayName)
                EnvReadingsLine(readings: sensor.envReadings)
                SensorFooter(
                    battery: sensor.attributes.batteryPercentage,
                    room: showRoom ? sensor.room?.name : nil
                )
            }
        } icon: {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(
                    sensor.isComfortable ? Color.secondary : Color.orange
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Individual open/close sensor row. showRoom: true appends the room name
// next to the battery level; used in the devices tab.
struct OpenCloseSensorRow: View {
    let sensor: DirigeraDevice
    let now: Date
    var showRoom: Bool = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.displayName)
                if sensor.isOpen, let duration = sensor.openDuration(now: now) {
                    let overdue = (sensor.openSeconds(now: now) ?? 0) >= 15 * 60
                    Text("open for \(duration)")
                        .font(.caption2)
                        .foregroundStyle(overdue ? Color.orange : .secondary)
                }
                SensorFooter(
                    battery: sensor.attributes.batteryPercentage,
                    room: showRoom ? sensor.room?.name : nil
                )
            }
        } icon: {
            Image(
                systemName: sensor.isOpen
                    ? "sensor.tag.radiowaves.forward.fill" : "sensor.fill"
            )
            .foregroundStyle(sensor.isOpen ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Section components

// Collapsible lights section with a toggle-all button in the header.
// Shows "No lights found" when the list is empty (devices tab).
// onToggleAll lets callers toggle lights in a single room or all rooms.
struct LightsSectionView: View {
    let lights: [DirigeraDevice]
    @Binding var isExpanded: Bool
    @Binding var pendingLightLevels: [String: Double]
    @Binding var colorPickerLightId: String?
    @Binding var actionError: String?
    var showRoom: Bool = false
    let onToggleAll: () async -> Void

    var body: some View {
        if lights.isEmpty {
            Label("No lights found", systemImage: "lightbulb.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let anyOn = lights.contains { $0.isOn }
            let onCount = lights.filter { $0.isOn }.count
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    ForEach(lights) { light in
                        LightRowView(
                            light: light,
                            pendingLightLevels: $pendingLightLevels,
                            colorPickerLightId: $colorPickerLightId,
                            actionError: $actionError,
                            showRoom: showRoom
                        )
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 10)
            } label: {
                Button {
                    Task { await onToggleAll() }
                } label: {
                    Image(systemName: anyOn ? "lightbulb.fill" : "lightbulb")
                        .foregroundStyle(
                            anyOn ? Color.orange : Color.primary
                        )
                }
                .buttonStyle(.bordered)
                .help(anyOn ? "Turn all off" : "Turn all on")
                Text(
                    onCount > 0 ? "\(onCount) of \(lights.count) on" : "All off"
                )
                .foregroundStyle(.primary)
            }
            if let error = actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// Collapsible env-sensor section. Header shows averaged readings;
// expanded content shows individual sensor rows.
// Renders nothing when sensors is empty.
struct EnvSensorsSectionView: View {
    let sensors: [DirigeraDevice]
    @Binding var isExpanded: Bool
    var showRoom: Bool = false

    var body: some View {
        let avgReadings = DirigeraDevice.averagedEnvReadings(from: sensors)
        if !avgReadings.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    ForEach(sensors) { sensor in
                        EnvSensorRow(sensor: sensor, showRoom: showRoom)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 15)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(
                            avgReadings.allSatisfy { !$0.outOfRange }
                                ? Color.primary : Color.orange
                        )
                    EnvReadingsLine(readings: avgReadings, isHeadline: true)
                }
                .padding(.leading, 4)
            }
        }
    }
}

// Collapsible open/close sensor section. Header shows open count;
// expanded content shows individual sensor rows.
// Renders nothing when sensors is empty.
struct OpenCloseSensorsSectionView: View {
    let sensors: [DirigeraDevice]
    let now: Date
    @Binding var isExpanded: Bool
    var showRoom: Bool = false

    var body: some View {
        if !sensors.isEmpty {
            let anyOpen = sensors.contains { $0.isOpen }
            let openCount = sensors.filter { $0.isOpen }.count
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    ForEach(sensors) { sensor in
                        OpenCloseSensorRow(
                            sensor: sensor,
                            now: now,
                            showRoom: showRoom
                        )
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: anyOpen
                            ? "sensor.tag.radiowaves.forward.fill"
                            : "sensor.fill"
                    )
                    .foregroundStyle(anyOpen ? Color.orange : Color.primary)
                    Text(
                        openCount > 0
                            ? "\(openCount) of \(sensors.count) open"
                            : "All closed"
                    )
                    .foregroundStyle(
                        openCount > 0 ? Color.orange : Color.primary
                    )
                }
            }
        }
    }
}
