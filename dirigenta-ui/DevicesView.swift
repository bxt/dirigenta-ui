import SwiftUI

struct DevicesView: View {
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @AppStorage("settings.devices.showLights") private var showLights = true
    @AppStorage("settings.devices.showEnvSensors") private var showEnvSensors = true
    @AppStorage("settings.devices.showSensors") private var showSensors = true
    @AppStorage("settings.devices.showOtherDevices") private var showOtherDevices = true

    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var actionError: String? = nil

    private var anyLightOn: Bool { appState.lights.contains { $0.isOn } }

    var body: some View {
        List {
            if showLights {
                Section {
                    if appState.lights.isEmpty {
                        Label("No lights found", systemImage: "lightbulb.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.lights) { light in
                            LightRowView(
                                light: light,
                                pendingLightLevels: $pendingLightLevels,
                                colorPickerLightId: $colorPickerLightId,
                                actionError: $actionError,
                                showRoom: true
                            )
                        }
                        if let error = actionError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } header: {
                    HStack {
                        Text("Lights")
                        Spacer()
                        Button {
                            Task { await toggleAllLights() }
                        } label: {
                            Image(systemName: anyLightOn ? "lightbulb.fill" : "lightbulb")
                                .foregroundStyle(anyLightOn ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if showEnvSensors && !appState.envSensors.isEmpty {
                Section("Environment") {
                    ForEach(appState.envSensors) { sensor in
                        EnvSensorRow(sensor: sensor, showRoom: true)
                    }
                }
            }
            if showSensors && !appState.sensors.isEmpty {
                Section("Sensors") {
                    ForEach(appState.sensors) { sensor in
                        OpenCloseSensorRow(sensor: sensor, now: now, showRoom: true)
                    }
                }
            }
            if showOtherDevices && !appState.otherDevices.isEmpty {
                Section("Other Devices") {
                    ForEach(appState.otherDevices) { device in
                        OtherDeviceRow(device: device)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Actions

    private func toggleAllLights() async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let newState = !anyLightOn
        for i in appState.lights.indices { appState.lights[i].attributes.isOn = newState }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        await withTaskGroup(of: Void.self) { group in
            for light in appState.lights {
                group.addTask { try? await client.setLight(id: light.id, isOn: newState) }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}

#Preview("Devices tab") {
    let state = AppState.preview()
    return DevicesView(now: Date())
        .frame(width: 300)
        .environmentObject(state)
        .environmentObject(state.mdns)
}
