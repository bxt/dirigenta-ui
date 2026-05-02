import SwiftUI

struct DevicesView: View {
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @AppStorage("settings.devices.showLights") private var showLights = true
    @AppStorage("settings.devices.showEnvSensors") private var showEnvSensors =
        true
    @AppStorage("settings.devices.showSensors") private var showSensors = true
    @AppStorage("settings.devices.showOtherDevices") private
        var showOtherDevices = true

    @State private var lightsExpanded: Bool = true
    @State private var envExpanded: Bool = true
    @State private var sensorsExpanded: Bool = true
    @State private var othersExpanded: Bool = true
    @State private var actionError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showLights {
                LightsSectionView(
                    lights: appState.lights,
                    isExpanded: $lightsExpanded,
                    pendingLightLevels: $pendingLightLevels,
                    colorPickerLightId: $colorPickerLightId,
                    actionError: $actionError,
                    showRoom: true,
                    onToggleAll: { await toggleAllLights() }
                )
            }
            if showEnvSensors && !appState.envSensors.isEmpty {
                Divider()
                EnvSensorsSectionView(
                    sensors: appState.envSensors,
                    isExpanded: $envExpanded,
                    showRoom: true
                )
            }
            if showSensors && !appState.sensors.isEmpty {
                Divider()
                OpenCloseSensorsSectionView(
                    sensors: appState.sensors,
                    now: now,
                    isExpanded: $sensorsExpanded,
                    showRoom: true
                )
            }
            if showOtherDevices && !appState.otherDevices.isEmpty {
                Divider()
                OtherDevicesSectionView(
                    devices: appState.otherDevices,
                    isExpanded: $othersExpanded
                )
            }
        }
    }

    // MARK: - Actions

    private func toggleAllLights() async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let anyOn = appState.lights.contains { $0.isOn }
        let newState = !anyOn
        for i in appState.lights.indices {
            appState.lights[i].attributes.isOn = newState
        }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        await withTaskGroup(of: Void.self) { group in
            for light in appState.lights {
                group.addTask {
                    try? await client.setLight(id: light.id, isOn: newState)
                }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}

#Preview("Devices tab") {
    let state = AppState.preview()
    return VStack(alignment: .leading, spacing: 8) {
        DevicesView(now: Date())
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}
