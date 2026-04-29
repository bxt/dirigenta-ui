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
    @State private var discoTask: Task<Void, Never>? = nil

    private var isDiscoActive: Bool { discoTask != nil }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await toggleLight() }
            } label: {
                Label {
                    Text(light.displayName)
                } icon: {
                    Image(systemName: light.lightIcon(isOn: light.isOn))
                        .foregroundStyle(
                            light.isOn ? Color.orange : Color.primary
                        )
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

            if light.isOn && light.isColorLight {
                Button {
                    isDiscoActive ? stopDisco() : startDisco()
                } label: {
                    Image(systemName: "sparkles").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDiscoActive ? Color.accentColor : Color.secondary)
                .help(isDiscoActive ? "Stop disco mode" : "Start disco mode")
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
        .onDisappear { stopDisco() }
        .onChange(of: light.isOn) { _, isOn in if !isOn { stopDisco() } }

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
                    .onChange(of: levelText) { _, newValue in
                        // Strip any non-digit characters
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue {
                            levelText = digits
                            return
                        }
                        // Only apply when the user is actively editing the field,
                        // not when levelText is updated programmatically from the slider.
                        guard levelFieldFocused else { return }
                        guard let value = Int(digits), (1...100).contains(value)
                        else { return }
                        pendingLightLevels[light.id] = Double(value)
                        Task { await setBrightness(to: value) }
                    }
                    .onChange(of: levelFieldFocused) { _, isFocused in
                        // Reset display if field was left empty or out of range
                        if !isFocused { levelText = "\(Int(displayValue))" }
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
                onSetLightLevel: { level in
                    Task { await setBrightness(to: level) }
                },
                onSetColorTemperature: { temp in
                    Task { await setColorTemperature(to: temp) }
                },
                onSetColor: { hue, sat in
                    Task { await setColor(hue: hue, saturation: sat) }
                }
            )
        }
    }

    // MARK: - Disco

    private func startDisco() {
        guard let ip = mdns.currentIPAddress else { return }
        let client = appState.makeClient(ip: ip)
        let id = light.id
        discoTask = Task {
            while !Task.isCancelled {
                let hue = Double.random(in: 0..<360)
                try? await client.setColor(id: id, hue: hue, saturation: 1.0)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopDisco() {
        guard discoTask != nil else { return }
        discoTask?.cancel()
        discoTask = nil
        let key = light.colorDefaultsKey
        guard let data = UserDefaults.standard.data(forKey: key),
            let preset = try? JSONDecoder().decode(LightColorPreset.self, from: data)
        else { return }
        Task {
            guard let ip = mdns.currentIPAddress else { return }
            let client = appState.makeClient(ip: ip)
            try? await client.applyColorPreset(preset, to: light.id)
        }
    }

    // MARK: - Actions

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

    private func setBrightness(to level: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let oldLevel = light.attributes.lightLevel
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withLightLevel(level) : $0
        }
        pendingLightLevels[light.id] = nil
        let client = appState.makeClient(ip: ip)
        do {
            try await client.setLightLevel(id: light.id, lightLevel: level)
        } catch {
            if let oldLevel {
                appState.lights = appState.lights.map {
                    $0.id == light.id ? $0.withLightLevel(oldLevel) : $0
                }
            }
            actionError = "Failed to set brightness for \(light.displayName)"
            Logger.api.error(
                "Brightness error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func setColorTemperature(to value: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let oldValue = light.attributes.colorTemperature
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
            if let oldValue {
                appState.lights = appState.lights.map {
                    $0.id == light.id ? $0.withColorTemperature(oldValue) : $0
                }
            }
            actionError = "Failed to set colour for \(light.displayName)"
            Logger.api.error(
                "Color temperature error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func setColor(hue: Double, saturation: Double) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let oldHue = light.attributes.colorHue
        let oldSaturation = light.attributes.colorSaturation
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
            if let oldHue, let oldSaturation {
                appState.lights = appState.lights.map {
                    $0.id == light.id
                        ? $0.withColor(hue: oldHue, saturation: oldSaturation) : $0
                }
            }
            actionError = "Failed to set colour for \(light.displayName)"
            Logger.api.error(
                "Color error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
