import SwiftUI

struct DevicesView: View {
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var lightsExpanded: Bool = true
    @State private var envExpanded: Bool = true
    @State private var sensorsExpanded: Bool = true
    @State private var actionError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LightsSectionView(
                lights: appState.lights,
                isExpanded: $lightsExpanded,
                pendingLightLevels: $pendingLightLevels,
                colorPickerLightId: $colorPickerLightId,
                actionError: $actionError,
                showRoom: true,
                onToggleAll: { await toggleAllLights() }
            )
            if !appState.envSensors.isEmpty {
                Divider()
                EnvSensorsSectionView(
                    sensors: appState.envSensors,
                    isExpanded: $envExpanded,
                    showRoom: true
                )
            }
            if !appState.sensors.isEmpty {
                Divider()
                OpenCloseSensorsSectionView(
                    sensors: appState.sensors,
                    now: now,
                    isExpanded: $sensorsExpanded,
                    showRoom: true
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
        appState.lights = appState.lights.map { $0.withIsOn(newState) }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        try? await client.setLightsIsOn(ids: appState.lights.map(\.id), isOn: newState)
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
