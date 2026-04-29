import OSLog
import SwiftUI

// Reusable attributed-string display for a list of env sensor readings.
// Used in both the rooms tab (averaged) and the devices tab (per-sensor).
struct EnvReadingsLine: View {
    let readings: [DirigeraDevice.Reading]

    var body: some View {
        Text(
            readings.enumerated().reduce(into: AttributedString()) { str, item in
                let (i, r) = item
                if i > 0 { str += AttributedString(" · ") }
                var part = AttributedString(r.text)
                if r.outOfRange { part.foregroundColor = .orange }
                str += part
            }
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
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
            .font(.caption)
            .fontWeight(.semibold)

        if !room.lights.isEmpty {
            HStack(spacing: 8) {
                Button { Task { await toggleRoomLights(room) } } label: {
                    Image(systemName: room.anyLightOn ? "lightbulb.fill" : "lightbulb")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(room.anyLightOn ? Color.primary : Color.secondary)
                .help(room.anyLightOn ? "Turn all off" : "Turn all on")

                Button {
                    expandedLightsRoomIds = expandedLightsRoomIds.symmetricDifference([room.id])
                } label: {
                    Image(systemName: "gearshape").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    expandedLightsRoomIds.contains(room.id) ? Color.accentColor : Color.secondary
                )
                .help("Light details")
            }

            if expandedLightsRoomIds.contains(room.id) {
                ForEach(room.lights) { light in
                    LightRowView(
                        light: light,
                        pendingLightLevels: $pendingLightLevels,
                        colorPickerLightId: $colorPickerLightId,
                        actionError: $actionError
                    )
                    .padding(.leading, 4)
                }
            }
        }

        let envReadings = DirigeraDevice.averagedEnvReadings(from: room.envSensors)
        if !envReadings.isEmpty {
            Button {
                expandedEnvRoomIds = expandedEnvRoomIds.symmetricDifference([room.id])
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                        .font(.caption)
                        .foregroundStyle(
                            envReadings.allSatisfy { !$0.outOfRange }
                                ? Color.secondary : Color.orange
                        )
                    EnvReadingsLine(readings: envReadings)
                }
            }
            .buttonStyle(.plain)

            if expandedEnvRoomIds.contains(room.id) {
                ForEach(room.envSensors) { sensor in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sensor.displayName)
                            EnvReadingsLine(readings: sensor.envReadings)
                            if let battery = sensor.attributes.batteryPercentage {
                                Text("\(battery)% battery")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(
                                sensor.isComfortable ? Color.secondary : Color.orange
                            )
                    }
                    .padding(.leading, 4)
                }
            }
        }

        if !room.sensors.isEmpty {
            Button {
                expandedSensorsRoomIds = expandedSensorsRoomIds.symmetricDifference([room.id])
            } label: {
                Image(
                    systemName: room.anySensorOpen
                        ? "sensor.tag.radiowaves.forward.fill" : "sensor.fill"
                )
                .foregroundStyle(room.anySensorOpen ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(room.anySensorOpen ? "A sensor is open" : "All sensors closed")

            if expandedSensorsRoomIds.contains(room.id) {
                ForEach(room.sensors) { sensor in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sensor.displayName)
                            if sensor.isOpen, let duration = sensor.openDuration(now: now) {
                                let overdue = (sensor.openSeconds(now: now) ?? 0) >= 15 * 60
                                Text("open for \(duration)")
                                    .font(.caption2)
                                    .foregroundStyle(overdue ? Color.orange : .secondary)
                            }
                            if let battery = sensor.attributes.batteryPercentage {
                                Text("\(battery)% battery")
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
                    .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - Data

    private var roomSummaries: [RoomSummary] {
        var byRoom: [String: (name: String, lights: [DirigeraDevice], sensors: [DirigeraDevice],
            envSensors: [DirigeraDevice])] = [:]
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
