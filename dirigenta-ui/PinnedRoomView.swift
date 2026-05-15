import SwiftUI

struct PinnedRoomView: View {
    let roomId: String
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @AppStorage("settings.rooms.showLights") private var showLights = true
    @AppStorage("settings.rooms.showPlugs") private var showPlugs = true
    @AppStorage("settings.rooms.showEnvSensors") private var showEnvSensors =
        true
    @AppStorage("settings.rooms.showSensors") private var showSensors = true
    @AppStorage("settings.rooms.showOtherDevices") private
        var showOtherDevices = true

    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var expandedPlugId: String? = nil
    @State private var actionError: String? = nil
    @State private var lightsExpanded = true
    @State private var plugsExpanded = true
    @State private var envExpanded = true
    @State private var sensorsExpanded = true
    @State private var othersExpanded = true

    private var lights: [DirigeraDevice] {
        appState.devices.lights.filter { $0.room?.id == roomId }
    }
    private var plugs: [DirigeraDevice] {
        appState.devices.smartPlugs.filter { $0.room?.id == roomId }
    }
    private var envSensors: [DirigeraDevice] {
        appState.devices.envSensors.filter { $0.room?.id == roomId }
    }
    private var sensors: [DirigeraDevice] {
        appState.devices.openCloseSensors.filter { $0.room?.id == roomId }
    }
    private var others: [DirigeraDevice] {
        appState.devices.others.filter { $0.room?.id == roomId }
    }

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
            if showPlugs && !plugs.isEmpty {
                SmartPlugsSectionView(
                    plugs: plugs,
                    isExpanded: $plugsExpanded,
                    expandedPlugId: $expandedPlugId,
                    actionError: $actionError,
                    onToggleAll: { await togglePlugs() }
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
            if showOtherDevices && !others.isEmpty {
                OtherDevicesSectionView(
                    devices: others,
                    isExpanded: $othersExpanded
                )
            }
        }
    }

    private func toggleLights() async {
        guard let ip = appState.currentHubIP,
            let client = appState.makeClient(ip: ip)
        else { return }
        let newState = !lights.contains { $0.isOn }
        let ids = Set(lights.map { $0.id })
        for i in appState.devices.indices
        where ids.contains(appState.devices[i].id) {
            appState.devices[i].attributes.isOn = newState
        }
        appState.syncPinnedState()
        await withTaskGroup(of: Void.self) { group in
            for light in lights {
                group.addTask {
                    try? await client.setLight(id: light.id, isOn: newState)
                }
            }
        }
        await appState.fetchDevices(ip: ip)
    }

    private func togglePlugs() async {
        guard let ip = appState.currentHubIP,
            let client = appState.makeClient(ip: ip)
        else { return }
        let newState = !plugs.contains { $0.isOn }
        let ids = Set(plugs.map { $0.id })
        for i in appState.devices.indices
        where ids.contains(appState.devices[i].id) {
            appState.devices[i].attributes.isOn = newState
        }
        appState.syncPinnedState()
        await withTaskGroup(of: Void.self) { group in
            for plug in plugs {
                guard let outletId = plug.attributes.outletId else { continue }
                group.addTask {
                    try? await client.setOutlet(id: outletId, isOn: newState)
                }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}
