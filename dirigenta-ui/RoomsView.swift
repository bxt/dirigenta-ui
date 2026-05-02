import OSLog
import SwiftUI

// MARK: - Rooms tab

private struct RoomSummary: Identifiable {
    let id: String
    let name: String
    let lights: [DirigeraDevice]
    let sensors: [DirigeraDevice]
    let envSensors: [DirigeraDevice]

    var anyLightOn: Bool { lights.contains { $0.isOn } }
}

struct RoomsView: View {
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @AppStorage("settings.rooms.showLights") private var showLights = true
    @AppStorage("settings.rooms.showEnvSensors") private var showEnvSensors = true
    @AppStorage("settings.rooms.showSensors") private var showSensors = true
    @AppStorage("settings.pinnedRoomId") private var pinnedRoomId: String = ""

    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var actionError: String? = nil

    var body: some View {
        let rooms = roomSummaries
        List {
            if rooms.isEmpty {
                Label("No rooms found", systemImage: "house.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rooms) { room in roomSection(room) }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Room section

    @ViewBuilder
    private func roomSection(_ room: RoomSummary) -> some View {
        let isPinned = pinnedRoomId == room.id
        Section {
            if showEnvSensors {
                let avgReadings = DirigeraDevice.averagedEnvReadings(from: room.envSensors)
                if !avgReadings.isEmpty {
                    Label {
                        EnvReadingsLine(readings: avgReadings, isHeadline: true)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(
                                avgReadings.allSatisfy { !$0.outOfRange }
                                    ? Color.secondary : Color.orange
                            )
                    }
                }
            }
            if showLights {
                ForEach(room.lights) { light in
                    LightRowView(
                        light: light,
                        pendingLightLevels: $pendingLightLevels,
                        colorPickerLightId: $colorPickerLightId,
                        actionError: $actionError
                    )
                }
            }
            if showSensors {
                ForEach(room.sensors) { sensor in
                    OpenCloseSensorRow(sensor: sensor, now: now)
                }
            }
        } header: {
            HStack {
                Text(room.name)
                    .font(.title3.weight(.semibold))
                    .textCase(nil)
                    .foregroundStyle(.primary)
                Spacer()
                if showLights && !room.lights.isEmpty {
                    Button {
                        Task { await toggleRoomLights(room) }
                    } label: {
                        Image(systemName: room.anyLightOn ? "lightbulb.fill" : "lightbulb")
                            .foregroundStyle(room.anyLightOn ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    pinnedRoomId = isPinned ? "" : room.id
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
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
                id: $0.key,
                name: $0.value.name,
                lights: $0.value.lights,
                sensors: $0.value.sensors,
                envSensors: $0.value.envSensors
            )
        }
    }

    // MARK: - Actions

    private func toggleRoomLights(_ room: RoomSummary) async {
        guard let ip = mdns.currentIPAddress else { return }
        let newState = !room.anyLightOn
        let ids = Set(room.lights.map { $0.id })
        for i in appState.lights.indices where ids.contains(appState.lights[i].id) {
            appState.lights[i].attributes.isOn = newState
        }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        await withTaskGroup(of: Void.self) { group in
            for light in room.lights {
                group.addTask {
                    try? await client.setLight(id: light.id, isOn: newState)
                }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}
