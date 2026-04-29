import OSLog
import SwiftUI

// Reusable attributed-string display for a list of env sensor readings.
// Used in both the rooms tab (averaged) and the devices tab (per-sensor).
// isHeadline: true → body-sized white text, used for the DisclosureGroup
// summary row; false (default) → caption2 secondary, used inside rows.
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

// Shared individual env-sensor row. Pass showRoom: true in the devices tab
// to append the room name next to the battery level.
struct EnvSensorRow: View {
    let sensor: DirigeraDevice
    var showRoom: Bool = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.displayName)
                EnvReadingsLine(readings: sensor.envReadings)
                let footer = [
                    sensor.attributes.batteryPercentage.map { "\($0)% battery" },
                    showRoom ? sensor.room?.name : nil,
                ].compactMap { $0 }
                if !footer.isEmpty {
                    Text(footer.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(sensor.isComfortable ? Color.secondary : Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Shared individual open/close sensor row. Pass showRoom: true in the devices
// tab to append the room name next to the battery level.
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
                let footer = [
                    sensor.attributes.batteryPercentage.map { "\($0)% battery" },
                    showRoom ? sensor.room?.name : nil,
                ].compactMap { $0 }
                if !footer.isEmpty {
                    Text(footer.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
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

private struct RoomSummary: Identifiable {
    let id: String
    let name: String
    let lights: [DirigeraDevice]
    let sensors: [DirigeraDevice]
    let envSensors: [DirigeraDevice]

    var anyLightOn: Bool { lights.contains { $0.isOn } }
    var anySensorOpen: Bool { sensors.contains { $0.isOpen } }
}

struct RoomsView: View {
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var actionError: String? = nil
    @State private var expandedLightsRoomIds: Set<String> = []
    @State private var expandedEnvRoomIds: Set<String> = []
    @State private var expandedSensorsRoomIds: Set<String> = []

    // Creates a Bool Binding from a Set<String>, toggling membership of `id`.
    private func membership(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let rooms = roomSummaries
            if rooms.isEmpty {
                Label("No rooms found", systemImage: "house.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rooms) { room in
                    roomSection(room)
                    if room.id != rooms.last?.id {
                        Divider()
                    }
                }
            }
            if let error = actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Room section

    @ViewBuilder
    private func roomSection(_ room: RoomSummary) -> some View {
        Text(room.name)
            .fontWeight(.semibold)

        // Lights: toggle button in the label, chevron expands individual controls.
        // The Button inside the label captures its own tap so clicking the
        // lightbulb only toggles all lights; the chevron handles expansion.
        if !room.lights.isEmpty {
            DisclosureGroup(
                isExpanded: membership(room.id, in: $expandedLightsRoomIds)
            ) {
                VStack(spacing: 8) {
                    ForEach(room.lights) { light in
                        LightRowView(
                            light: light,
                            pendingLightLevels: $pendingLightLevels,
                            colorPickerLightId: $colorPickerLightId,
                            actionError: $actionError
                        )
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 8)
            } label: {
                let onCount = room.lights.filter { $0.isOn }.count
                Button {
                    Task { await toggleRoomLights(room) }
                } label: {
                    Image(
                        systemName: room.anyLightOn
                            ? "lightbulb.fill" : "lightbulb"
                    )
                }
                .buttonStyle(.bordered)
                .help(room.anyLightOn ? "Turn all off" : "Turn all on")
                Text(
                    onCount > 0
                        ? "\(onCount) of \(room.lights.count) on" : "All off"
                )
                .foregroundStyle(.primary)
            }
        }

        // Averaged env-sensor readings; chevron expands per-sensor detail.
        let envReadings = DirigeraDevice.averagedEnvReadings(
            from: room.envSensors
        )
        if !envReadings.isEmpty {
            DisclosureGroup(
                isExpanded: membership(room.id, in: $expandedEnvRoomIds)
            ) {
                VStack(spacing: 8) {
                    ForEach(room.envSensors) { sensor in
                        EnvSensorRow(sensor: sensor)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 8)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(
                            envReadings.allSatisfy { !$0.outOfRange }
                                ? Color.primary : Color.orange
                        )
                    EnvReadingsLine(readings: envReadings, isHeadline: true)
                }
            }
        }

        // Open/close sensor status; chevron expands per-sensor detail.
        if !room.sensors.isEmpty {
            DisclosureGroup(
                isExpanded: membership(room.id, in: $expandedSensorsRoomIds)
            ) {
                VStack(spacing: 8) {
                    ForEach(room.sensors) { sensor in
                        OpenCloseSensorRow(sensor: sensor, now: now)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 8)
            } label: {
                let openCount = room.sensors.filter { $0.isOpen }.count
                HStack(spacing: 4) {
                    Image(
                        systemName: room.anySensorOpen
                            ? "sensor.tag.radiowaves.forward.fill"
                            : "sensor.fill"
                    )
                    .foregroundStyle(
                        room.anySensorOpen ? Color.orange : Color.primary
                    )
                    Text(
                        openCount > 0
                            ? "\(openCount) of \(room.sensors.count) open"
                            : "All closed"
                    )
                    .foregroundStyle(
                        openCount > 0 ? Color.orange : Color.primary
                    )
                }
            }
        }
    }

    // MARK: - Data

    private var roomSummaries: [RoomSummary] {
        var byRoom:
            [String: (
                name: String, lights: [DirigeraDevice],
                sensors: [DirigeraDevice],
                envSensors: [DirigeraDevice]
            )] = [:]
        for device in appState.lights {
            guard let room = device.room else { continue }
            var e = byRoom[room.id] ?? (room.name, [], [], [])
            e.lights.append(device)
            byRoom[room.id] = e
        }
        for device in appState.sensors {
            guard let room = device.room else { continue }
            var e = byRoom[room.id] ?? (room.name, [], [], [])
            e.sensors.append(device)
            byRoom[room.id] = e
        }
        for device in appState.envSensors {
            guard let room = device.room else { continue }
            var e = byRoom[room.id] ?? (room.name, [], [], [])
            e.envSensors.append(device)
            byRoom[room.id] = e
        }
        return byRoom.sorted { $0.value.name < $1.value.name }.map {
            RoomSummary(
                id: $0.key, name: $0.value.name,
                lights: $0.value.lights, sensors: $0.value.sensors,
                envSensors: $0.value.envSensors
            )
        }
    }

    // MARK: - Actions

    private func toggleRoomLights(_ room: RoomSummary) async {
        guard let ip = mdns.currentIPAddress else { return }
        let newState = !room.anyLightOn
        let ids = Set(room.lights.map { $0.id })
        appState.lights = appState.lights.map { ids.contains($0.id) ? $0.withIsOn(newState) : $0 }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        await withTaskGroup(of: Void.self) { group in
            for light in room.lights {
                group.addTask { try? await client.setLight(id: light.id, isOn: newState) }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}
