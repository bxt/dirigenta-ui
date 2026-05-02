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
    @State private var lightsExpanded = true
    @State private var envExpanded = true
    @State private var sensorsExpanded = true

    private var lights: [DirigeraDevice] { appState.lights.filter { $0.room?.id == roomId } }
    private var envSensors: [DirigeraDevice] { appState.envSensors.filter { $0.room?.id == roomId } }
    private var sensors: [DirigeraDevice] { appState.sensors.filter { $0.room?.id == roomId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showLights && !lights.isEmpty {
                LightsSectionView(
                    lights: lights,
                    isExpanded: $lightsExpanded,
                    pendingLightLevels: $pendingLightLevels,
                    colorPickerLightId: $colorPickerLightId,
                    actionError: $actionError,
                    onToggleAll: { await toggleLights() }
                )
            }
            if showEnvSensors && !envSensors.isEmpty {
                EnvSensorsSectionView(
                    sensors: envSensors,
                    isExpanded: $envExpanded
                )
            }
            if showSensors && !sensors.isEmpty {
                OpenCloseSensorsSectionView(
                    sensors: sensors,
                    now: now,
                    isExpanded: $sensorsExpanded
                )
            }
        }
    }

    private func toggleLights() async {
        guard let ip = mdns.currentIPAddress else { return }
        let newState = !lights.contains { $0.isOn }
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
