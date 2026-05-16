import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    // MARK: - Devices tab visibility
    @AppStorage("settings.devices.showLights") private var devicesShowLights =
        true
    @AppStorage("settings.devices.showPlugs") private var devicesShowPlugs =
        true
    @AppStorage("settings.devices.showEnvSensors") private
        var devicesShowEnvSensors = true
    @AppStorage("settings.devices.showSensors") private var devicesShowSensors =
        true
    @AppStorage("settings.devices.showOtherDevices") private
        var devicesShowOtherDevices = true

    // MARK: - Rooms tab visibility
    @AppStorage("settings.rooms.showLights") private var roomsShowLights = true
    @AppStorage("settings.rooms.showPlugs") private var roomsShowPlugs = true
    @AppStorage("settings.rooms.showEnvSensors") private
        var roomsShowEnvSensors = true
    @AppStorage("settings.rooms.showSensors") private var roomsShowSensors =
        true
    @AppStorage("settings.rooms.showOtherDevices") private
        var roomsShowOtherDevices = true

    // MARK: - Notifications
    @AppStorage("settings.notifications.openWindow") private
        var notifyOpenWindow = true
    @AppStorage("settings.notifications.closeWindow") private
        var notifyCloseWindow = true
    @AppStorage("settings.notifications.waterLeak") private
        var notifyWaterLeak = true
    @AppStorage("settings.notifications.ipc") private var notifyIPC = true

    @State private var hubPendingRemoval: Hub?
    @State private var showingAddHub = false

    var body: some View {
        Form {
            Section("Hubs") {
                if appState.hubs.isEmpty {
                    Text("No hubs paired yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.hubs) { hub in
                        HubRow(
                            hub: hub,
                            isSelected: hub.id == appState.selectedHubID,
                            onSelect: { appState.switchHub(to: hub.id) },
                            onRename: { newName in
                                appState.renameHub(hub.id, to: newName)
                            },
                            onRemove: { hubPendingRemoval = hub }
                        )
                    }
                }
                Button {
                    showingAddHub = true
                } label: {
                    Label("Add Hub…", systemImage: "plus")
                }
                Button {
                    appState.addDemoHub()
                } label: {
                    Label("Add Demo Hub", systemImage: "play.tv")
                }
                .disabled(appState.hasDemoHub)
                .help(
                    appState.hasDemoHub
                        ? "Demo hub already added"
                        : "Add a built-in fake hub with sample devices for trying out the app"
                )
            }

            Section("Devices") {
                Toggle("Lights", isOn: $devicesShowLights)
                Toggle("Smart Plugs", isOn: $devicesShowPlugs)
                Toggle("Environment Sensors", isOn: $devicesShowEnvSensors)
                Toggle("Sensors", isOn: $devicesShowSensors)
                Toggle("Other Devices", isOn: $devicesShowOtherDevices)
            }

            Section("Rooms") {
                Toggle("Lights", isOn: $roomsShowLights)
                Toggle("Smart Plugs", isOn: $roomsShowPlugs)
                Toggle("Environment Sensors", isOn: $roomsShowEnvSensors)
                Toggle("Sensors", isOn: $roomsShowSensors)
                Toggle("Other Devices", isOn: $roomsShowOtherDevices)
            }

            Section("Notifications") {
                Toggle("Notify when to open a window", isOn: $notifyOpenWindow)
                Toggle(
                    "Notify when to close a window",
                    isOn: $notifyCloseWindow
                )
                Toggle("Notify on water leak", isOn: $notifyWaterLeak)
                Toggle(isOn: $notifyIPC) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow –notify IPC")
                        Text(
                            "Lets any local process trigger a light flash via the command line"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 420)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
        .sheet(isPresented: $showingAddHub) {
            VStack(alignment: .leading, spacing: 8) {
                PairingView(onPaired: { showingAddHub = false })
                HStack {
                    Spacer()
                    Button("Cancel") { showingAddHub = false }
                }
            }
            .padding(16)
            .frame(width: 360)
            .environmentObject(appState)
            .environmentObject(appState.mdns)
        }
        .alert(
            "Remove this hub?",
            isPresented: Binding(
                get: { hubPendingRemoval != nil },
                set: { if !$0 { hubPendingRemoval = nil } }
            ),
            presenting: hubPendingRemoval
        ) { hub in
            Button("Cancel", role: .cancel) { hubPendingRemoval = nil }
            Button("Remove", role: .destructive) {
                appState.removeHub(hub.id)
                hubPendingRemoval = nil
            }
        } message: { hub in
            Text(
                "\(hub.displayName) will be removed from this app. The hub itself isn't affected."
            )
        }
    }

}

private struct HubRow: View {
    let hub: Hub
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var draftName: String = ""
    @State private var isEditing = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onSelect) {
                Image(
                    systemName: isSelected
                        ? "largecircle.fill.circle" : "circle"
                )
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Selected hub" : "Switch to this hub")

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField(
                        "Name",
                        text: $draftName,
                        onCommit: { commitRename() }
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 4) {
                        Text(hub.displayName)
                        if hub.kind == .demo {
                            Image(systemName: "play.tv")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let ip = hub.lastKnownIP {
                    Text(ip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if hub.kind == .demo {
                    Text("Built-in fake hub")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isEditing {
                Button("Save") { commitRename() }
                    .buttonStyle(.borderless)
                Button("Cancel") {
                    isEditing = false
                    draftName = hub.displayName
                }
                .buttonStyle(.borderless)
            } else {
                Menu {
                    Button("Rename") {
                        draftName = hub.displayName
                        isEditing = true
                    }
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private func commitRename() {
        onRename(draftName)
        isEditing = false
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.preview())
}

#Preview("With multiple hubs") {
    let state = AppState.preview()
    state.hubs.append(
        Hub.real(displayName: "Cottage", accessToken: "tok-cottage")
    )
    return SettingsView()
        .environmentObject(state)
}
