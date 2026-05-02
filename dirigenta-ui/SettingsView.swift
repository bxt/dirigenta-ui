import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    // MARK: - Default tab
    @AppStorage("settings.defaultTab") private var defaultTab: MenuTab = .devices

    // MARK: - Devices tab visibility
    @AppStorage("settings.devices.showLights") private var devicesShowLights = true
    @AppStorage("settings.devices.showEnvSensors") private var devicesShowEnvSensors = true
    @AppStorage("settings.devices.showSensors") private var devicesShowSensors = true
    @AppStorage("settings.devices.showOtherDevices") private var devicesShowOtherDevices = true

    // MARK: - Rooms tab visibility
    @AppStorage("settings.rooms.showLights") private var roomsShowLights = true
    @AppStorage("settings.rooms.showEnvSensors") private var roomsShowEnvSensors = true
    @AppStorage("settings.rooms.showSensors") private var roomsShowSensors = true

    // MARK: - Notifications
    @AppStorage("settings.notifications.openWindow") private var notifyOpenWindow = true
    @AppStorage("settings.notifications.closeWindow") private var notifyCloseWindow = true
    @AppStorage("settings.notifications.ipc") private var notifyIPC = true

    var body: some View {
        Form {
            Section("General") {
                Picker("Default tab", selection: $defaultTab) {
                    Text("Devices").tag(MenuTab.devices)
                    Text("Rooms").tag(MenuTab.rooms)
                }
            }

            Section("Devices") {
                Toggle("Lights", isOn: $devicesShowLights)
                Toggle("Environment Sensors", isOn: $devicesShowEnvSensors)
                Toggle("Sensors", isOn: $devicesShowSensors)
                Toggle("Other Devices", isOn: $devicesShowOtherDevices)
            }

            Section("Rooms") {
                Toggle("Lights", isOn: $roomsShowLights)
                Toggle("Environment Sensors", isOn: $roomsShowEnvSensors)
                Toggle("Sensors", isOn: $roomsShowSensors)
            }

            Section("Notifications") {
                Toggle("Notify when to open a window", isOn: $notifyOpenWindow)
                Toggle("Notify when to close a window", isOn: $notifyCloseWindow)
                Toggle(isOn: $notifyIPC) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow –notify IPC")
                        Text("Lets any local process trigger a light flash via the command line")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Account") {
                Button(role: .destructive) {
                    appState.pinnedLightId = nil
                    appState.accessToken = ""
                } label: {
                    Text("Clear Saved Token")
                        .frame(maxWidth: .infinity)
                }
                .disabled(appState.accessToken.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 400)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.preview())
}
