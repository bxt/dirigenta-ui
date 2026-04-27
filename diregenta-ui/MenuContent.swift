
import SwiftUI
import AppKit
import OSLog

private struct DiscoveryStatusView: View {
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        Group {
            if let ip = mdns.currentIPAddress {
                Label("Hub: \(ip)", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if mdns.isResolving {
                Label("Discovering hub…", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Hub not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver
    @State private var tempToken: String = ""
    @State private var toggleError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.accessToken.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DiscoveryStatusView()
                    Divider()
                    Text("Enter Dirigera Access Token")
                        .font(.headline)
                    SecureField("Access Token", text: $tempToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                    HStack {
                        Spacer()
                        Button("Save") {
                            let trimmed = tempToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            appState.accessToken = trimmed
                        }
                        .disabled(tempToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(8)
                .onAppear { mdns.start() }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let name = appState.gatewayName {
                        Text(name)
                            .font(.headline)
                    }
                    DiscoveryStatusView()
                    Divider()
                    lightsSection
                    sensorsSection
                    envSensorsSection
                }
                .padding(8)
                .onAppear { mdns.start() }
                .task(id: mdns.currentIPAddress) {
                    // AppState auto-fetches devices when the IP resolves.
                    // This task only maintains the WebSocket for live updates.
                    guard let ip = mdns.currentIPAddress else { return }
                    while !Task.isCancelled {
                        let client = DirigeraClient(ip: ip, token: appState.accessToken)
                        for await event in client.eventStream() {
                            guard !appState.isLoadingDevices else { continue }
                            appState.applyEvent(event)
                        }
                        Logger.webSocket.info("Reconnecting in 5s…")
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        now = Date()
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                if !appState.accessToken.isEmpty && appState.isLoadingDevices {
                    Label("Refreshing…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !appState.accessToken.isEmpty {
                    Button("Clear Token") {
                        appState.pinnedLightId = nil
                        appState.accessToken = ""
                    }
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var lightsSection: some View {
        if appState.lights.isEmpty {
            if appState.isLoadingDevices {
                Label("Loading lights…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.devicesError != nil {
                Label("Failed to load lights", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("No lights found", systemImage: "lightbulb.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(appState.lights) { light in
                HStack(spacing: 4) {
                    Button {
                        Task { await toggleLight(light) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(light.displayName)
                                if let sub = subtitle(room: light.room?.name, battery: nil) {
                                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if light.isOn && light.supportsColorControls {
                        Button {
                            colorPickerLightId = colorPickerLightId == light.id ? nil : light.id
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(colorPickerLightId == light.id ? Color.accentColor : Color.secondary)
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
                        Image(systemName: appState.pinnedLightId == light.id ? "pin.fill" : "pin")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.pinnedLightId == light.id ? Color.accentColor : Color.secondary)
                    .help(appState.pinnedLightId == light.id ? "Unpin light" : "Pin to menu bar")
                }
                if light.isOn, let level = light.attributes.lightLevel {
                    Slider(
                        value: Binding(
                            get: { pendingLightLevels[light.id] ?? Double(level) },
                            set: { pendingLightLevels[light.id] = $0 }
                        ),
                        in: 1...100
                    ) { editing in
                        if !editing, let pending = pendingLightLevels[light.id] {
                            Task { await setBrightness(light, to: Int(pending)) }
                        }
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 4)
                }
                if light.isOn && colorPickerLightId == light.id {
                    LightColorControls(
                        light: light,
                        onSetColorTemperature: { temp in
                            Task { await setColorTemperature(light, to: temp) }
                        },
                        onSetColor: { hue, saturation in
                            Task { await setColor(light, hue: hue, saturation: saturation) }
                        }
                    )
                }
            }
            if let error = toggleError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var sensorsSection: some View {
        if !appState.sensors.isEmpty {
            Divider()
            ForEach(appState.sensors) { sensor in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sensor.displayName)
                        if sensor.isOpen, let duration = openDuration(sensor) {
                            Text("open for \(duration)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let sub = subtitle(room: sensor.room?.name, battery: sensor.attributes.batteryPercentage) {
                            Text(sub).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: sensor.isOpen ? "sensor.tag.radiowaves.forward.fill" : "sensor.fill")
                        .foregroundStyle(sensor.isOpen ? Color.orange : Color.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var envSensorsSection: some View {
        if !appState.envSensors.isEmpty {
            Divider()
            ForEach(appState.envSensors) { sensor in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sensor.displayName)
                        let readings = sensor.envReadings
                        if !readings.isEmpty {
                            Text(readings.enumerated().reduce(into: AttributedString()) { str, item in
                                let (i, r) = item
                                if i > 0 { str += AttributedString(" · ") }
                                var part = AttributedString(r.text)
                                if r.outOfRange { part.foregroundColor = .orange }
                                str += part
                            })
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        if let sub = subtitle(room: sensor.room?.name, battery: sensor.attributes.batteryPercentage) {
                            Text(sub).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(sensor.isComfortable ? Color.secondary : Color.yellow)
                }
            }
        }
    }

    // MARK: - Helpers

    private func subtitle(room: String?, battery: Int?) -> String? {
        let parts = [room, battery.map { "\($0)% battery" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoWithoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func openDuration(_ sensor: DirigeraDevice) -> String? {
        guard let raw = sensor.lastSeen else { return nil }
        let date = Self.isoWithFractional.date(from: raw) ?? Self.isoWithoutFractional.date(from: raw)
        guard let date else { return nil }
        let s = Int(now.timeIntervalSince(date))
        guard s > 0 else { return nil }
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    // MARK: - Light actions

    private func setBrightness(_ light: DirigeraDevice, to level: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        appState.lights = appState.lights.map { $0.id == light.id ? $0.withLightLevel(level) : $0 }
        pendingLightLevels[light.id] = nil
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setLightLevel(id: light.id, lightLevel: level)
        } catch {
            Logger.api.error("Brightness error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setColorTemperature(_ light: DirigeraDevice, to value: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        appState.lights = appState.lights.map { $0.id == light.id ? $0.withColorTemperature(value) : $0 }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setColorTemperature(id: light.id, colorTemperature: value)
        } catch {
            Logger.api.error("Color temperature error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setColor(_ light: DirigeraDevice, hue: Double, saturation: Double) async {
        guard let ip = mdns.currentIPAddress else { return }
        appState.lights = appState.lights.map { $0.id == light.id ? $0.withColor(hue: hue, saturation: saturation) : $0 }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setColor(id: light.id, hue: hue, saturation: saturation)
        } catch {
            Logger.api.error("Color error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func toggleLight(_ light: DirigeraDevice) async {
        guard let ip = mdns.currentIPAddress else { return }
        toggleError = nil
        let newState = !light.isOn
        appState.lights = appState.lights.map { $0.id == light.id ? $0.withIsOn(newState) : $0 }
        appState.syncPinnedState()
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setLight(id: light.id, isOn: newState)
            await appState.fetchDevices(ip: ip)
        } catch {
            appState.lights = appState.lights.map { $0.id == light.id ? $0.withIsOn(!newState) : $0 }
            toggleError = "Failed to toggle \(light.displayName)"
            Logger.api.error("Toggle error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    let state = AppState.preview()
    MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}
