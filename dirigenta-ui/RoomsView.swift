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

    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var actionError: String? = nil
    @State private var expandedLightsRoomIds: Set<String> = []
    @State private var expandedEnvRoomIds: Set<String> = []
    @State private var expandedSensorsRoomIds: Set<String> = []

    // Creates a Bool Binding from a Set<String>, toggling membership of `id`.
    private func membership(_ id: String, in set: Binding<Set<String>>)
        -> Binding<Bool>
    {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: {
                if $0 {
                    set.wrappedValue.insert(id)
                } else {
                    set.wrappedValue.remove(id)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        }
    }

    // MARK: - Room section

    @ViewBuilder
    private func roomSection(_ room: RoomSummary) -> some View {
        Text(room.name)
            .fontWeight(.semibold).padding(.top, 8)

        if !room.lights.isEmpty {
            LightsSectionView(
                lights: room.lights,
                isExpanded: membership(room.id, in: $expandedLightsRoomIds),
                pendingLightLevels: $pendingLightLevels,
                colorPickerLightId: $colorPickerLightId,
                actionError: $actionError,
                onToggleAll: { await toggleRoomLights(room) }
            )
        }

        EnvSensorsSectionView(
            sensors: room.envSensors,
            isExpanded: membership(room.id, in: $expandedEnvRoomIds)
        )

        OpenCloseSensorsSectionView(
            sensors: room.sensors,
            now: now,
            isExpanded: membership(room.id, in: $expandedSensorsRoomIds)
        )
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
        appState.lights = appState.lights.map {
            ids.contains($0.id) ? $0.withIsOn(newState) : $0
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
