import OSLog
import SwiftUI

struct LightRowView: View {
    let light: DirigeraDevice
    @Binding var pendingLightLevels: [String: Double]
    @Binding var colorPickerLightId: String?
    @Binding var actionError: String?
    var showRoom: Bool = false

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var levelText: String = ""
    @FocusState private var levelFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await toggleLight() }
            } label: {
                Label {
                    Text(light.displayName)
                } icon: {
                    Image(systemName: light.lightIcon(isOn: light.isOn))
                        .foregroundStyle(light.isOn ? Color.orange : Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showRoom, let roomName = light.room?.name {
                Text(roomName).font(.caption2).foregroundStyle(.secondary)
            }

            if light.isOn && light.supportsColorControls {
                Button {
                    colorPickerLightId =
                        colorPickerLightId == light.id ? nil : light.id
                } label: {
                    Image(systemName: "gearshape").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    colorPickerLightId == light.id
                        ? Color.accentColor : Color.secondary
                )
                .help("Color settings")
            }

            Button {
                if appState.pinnedLightId == light.id {
                    appState.pinnedLightId = nil
                } else {
                    appState.pinnedLightId = light.id
                    appState.pinnedLightIsOn = light.isOn
                }
            } label: {
                Image(
                    systemName: appState.pinnedLightId == light.id
                        ? "pin.fill" : "pin"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                appState.pinnedLightId == light.id
                    ? Color.accentColor : Color.secondary
            )
            .help(
                appState.pinnedLightId == light.id
                    ? "Unpin light" : "Pin to menu bar"
            )
        }

        if light.isOn, let level = light.attributes.lightLevel {
            let displayValue = pendingLightLevels[light.id] ?? Double(level)
            HStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { displayValue },
                        set: { pendingLightLevels[light.id] = $0 }
                    ),
                    in: 1...100
                ) { editing in
                    if !editing, let pending = pendingLightLevels[light.id] {
                        Task { await setBrightness(to: Int(pending)) }
                    }
                }
                TextField("", text: $levelText)
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.squareBorder)
                    .focused($levelFieldFocused)
                    .onSubmit { commitLevelText() }
                    .onChange(of: levelFieldFocused) { _, isFocused in
                        if !isFocused { commitLevelText() }
                    }
            }
            .padding(.leading, 22)
            .padding(.trailing, 4)
            .onAppear { levelText = "\(Int(displayValue))" }
            .onChange(of: displayValue) { _, newValue in
                if !levelFieldFocused { levelText = "\(Int(newValue))" }
            }
        }

        if light.isOn && colorPickerLightId == light.id {
            LightColorControls(
                light: light,
                onSetColorTemperature: { temp in
                    Task { await setColorTemperature(to: temp) }
                },
                onSetColor: { hue, sat in
                    Task { await setColor(hue: hue, saturation: sat) }
                }
            )
        }
    }

    private func toggleLight() async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let newState = !light.isOn
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withIsOn(newState) : $0
        }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        do {
            try await client.setLight(id: light.id, isOn: newState)
            await appState.fetchDevices(ip: ip)
        } catch {
            appState.lights = appState.lights.map {
                $0.id == light.id ? $0.withIsOn(!newState) : $0
            }
            actionError = "Failed to toggle \(light.displayName)"
            Logger.api.error(
                "Toggle error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func commitLevelText() {
        guard let raw = Int(levelText.trimmingCharacters(in: .whitespaces)) else {
            // Reset display to current value on invalid input
            if let level = light.attributes.lightLevel {
                levelText = "\(pendingLightLevels[light.id].map(Int.init) ?? level)"
            }
            return
        }
        let clamped = min(100, max(1, raw))
        levelText = "\(clamped)"
        Task { await setBrightness(to: clamped) }
    }

    private func setBrightness(to level: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withLightLevel(level) : $0
        }
        pendingLightLevels[light.id] = nil
        let client = appState.makeClient(ip: ip)
        do {
            try await client.setLightLevel(id: light.id, lightLevel: level)
        } catch {
            actionError = "Failed to set brightness for \(light.displayName)"
            Logger.api.error(
                "Brightness error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func setColorTemperature(to value: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withColorTemperature(value) : $0
        }
        let client = appState.makeClient(ip: ip)
        do {
            try await client.setColorTemperature(
                id: light.id,
                colorTemperature: value
            )
        } catch {
            actionError = "Failed to set colour for \(light.displayName)"
            Logger.api.error(
                "Color temperature error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func setColor(hue: Double, saturation: Double) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        appState.lights = appState.lights.map {
            $0.id == light.id
                ? $0.withColor(hue: hue, saturation: saturation) : $0
        }
        let client = appState.makeClient(ip: ip)
        do {
            try await client.setColor(
                id: light.id,
                hue: hue,
                saturation: saturation
            )
        } catch {
            actionError = "Failed to set colour for \(light.displayName)"
            Logger.api.error(
                "Color error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
