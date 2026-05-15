import SwiftUI

struct DevicesView: View {
    let now: Date

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @AppStorage("settings.devices.showLights") private var showLights = true
    @AppStorage("settings.devices.showPlugs") private var showPlugs = true
    @AppStorage("settings.devices.showEnvSensors") private var showEnvSensors =
        true
    @AppStorage("settings.devices.showSensors") private var showSensors = true
    @AppStorage("settings.devices.showOtherDevices") private
        var showOtherDevices = true
    @AppStorage("settings.devices.expandLights")  private var lightsExpanded: Bool = true
    @AppStorage("settings.devices.expandPlugs")  private var plugsExpanded: Bool = true
    @AppStorage("settings.devices.expandEnvSensors")  private var envExpanded: Bool = true
    @AppStorage("settings.devices.expandSensors")  private var sensorsExpanded: Bool = true
    @AppStorage("settings.devices.expandOtherDevices")  private var othersExpanded: Bool = true

    @State private var actionError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var expandedPlugId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showLights {
                LightsSectionView(
                    lights: appState.devices.lights,
                    isExpanded: $lightsExpanded,
                    pendingLightLevels: $pendingLightLevels,
                    colorPickerLightId: $colorPickerLightId,
                    actionError: $actionError,
                    showRoom: true,
                    onToggleAll: { await toggleAllLights() }
                )
            }
            if showPlugs {
                Divider()
                SmartPlugsSectionView(
                    plugs: appState.devices.smartPlugs,
                    isExpanded: $plugsExpanded,
                    expandedPlugId: $expandedPlugId,
                    actionError: $actionError,
                    showRoom: true,
                    onToggleAll: { await toggleAllPlugs() }
                )
            }
            if showEnvSensors && !appState.devices.envSensors.isEmpty {
                Divider()
                EnvSensorsSectionView(
                    sensors: appState.devices.envSensors,
                    isExpanded: $envExpanded,
                    showRoom: true
                )
            }
            if showSensors && !appState.devices.openCloseSensors.isEmpty {
                Divider()
                OpenCloseSensorsSectionView(
                    sensors: appState.devices.openCloseSensors,
                    now: now,
                    isExpanded: $sensorsExpanded,
                    showRoom: true
                )
            }
            if showOtherDevices && !appState.devices.others.isEmpty {
                Divider()
                OtherDevicesSectionView(
                    devices: appState.devices.others,
                    isExpanded: $othersExpanded
                )
            }
        }
    }

    // MARK: - Actions

    private func toggleAllLights() async {
        guard let ip = appState.currentHubIP,
            let client = appState.makeClient(ip: ip)
        else { return }
        actionError = nil
        let lights = appState.devices.lights
        let anyOn = lights.contains { $0.isOn }
        let newState = !anyOn
        for i in appState.devices.indices where appState.devices[i].isLight {
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

    private func toggleAllPlugs() async {
        guard let ip = appState.currentHubIP,
            let client = appState.makeClient(ip: ip)
        else { return }
        actionError = nil
        let plugs = appState.devices.smartPlugs
        let anyOn = plugs.contains { $0.isOn }
        let newState = !anyOn
        for i in appState.devices.indices where appState.devices[i].isSmartPlug {
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
