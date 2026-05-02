import SwiftUI

struct PinnedRoomView: View {
    let roomId: String
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @AppStorage("settings.rooms.showLights") private var showLights = true
    @AppStorage("settings.rooms.showEnvSensors") private var showEnvSensors = true
    @AppStorage("settings.rooms.showSensors") private var showSensors = true

    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var actionError: String? = nil

    private var lights: [DirigeraDevice] { appState.lights.filter { $0.room?.id == roomId } }
    private var envSensors: [DirigeraDevice] { appState.envSensors.filter { $0.room?.id == roomId } }
    private var sensors: [DirigeraDevice] { appState.sensors.filter { $0.room?.id == roomId } }
    private var anyLightOn: Bool { lights.contains { $0.isOn } }

    var body: some View {
        List {
            Section {
                if showEnvSensors {
                    let avgReadings = DirigeraDevice.averagedEnvReadings(from: envSensors)
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
                    ForEach(lights) { light in
                        LightRowView(
                            light: light,
                            pendingLightLevels: $pendingLightLevels,
                            colorPickerLightId: $colorPickerLightId,
                            actionError: $actionError
                        )
                    }
                    if let error = actionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if showSensors {
                    ForEach(sensors) { sensor in
                        OpenCloseSensorRow(sensor: sensor, now: now)
                    }
                }
            } header: {
                HStack {
                    Spacer()
                    if showLights && !lights.isEmpty {
                        Button {
                            Task { await toggleLights() }
                        } label: {
                            Image(systemName: anyLightOn ? "lightbulb.fill" : "lightbulb")
                                .foregroundStyle(anyLightOn ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func toggleLights() async {
        guard let ip = mdns.currentIPAddress else { return }
        let newState = !anyLightOn
        let ids = Set(lights.map { $0.id })
        for i in appState.lights.indices where ids.contains(appState.lights[i].id) {
            appState.lights[i].attributes.isOn = newState
        }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        await withTaskGroup(of: Void.self) { group in
            for light in lights {
                group.addTask { try? await client.setLight(id: light.id, isOn: newState) }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}
