
import SwiftUI
import AppKit

private enum PairingStep {
    case idle
    case requesting
    case awaitingButtonPress(ip: String, code: String, verifier: String)
    case exchanging
    case failed(String)
}

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
    @State private var tempToken: String = ""
    @State private var pairingStep: PairingStep = .idle
    @State private var gatewayName: String? = nil
    @State private var lights: [DirigeraDevice] = []
    @State private var sensors: [DirigeraDevice] = []
    @State private var envSensors: [DirigeraDevice] = []
    @State private var envSensorIdMap: [String: String] = [:]
    @State private var isLoadingLights = false
    @State private var lightsError: String? = nil
    @State private var toggleError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var now = Date()
    @EnvironmentObject private var mdns: MDNSResolver

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.accessToken.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DiscoveryStatusView()
                    Divider()
                    pairingView
                }
                .padding(8)
                .onAppear { mdns.start() }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let name = gatewayName {
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
                    guard let ip = mdns.currentIPAddress else { return }
                    await fetchDevices(ip: ip)
                    while !Task.isCancelled {
                        let client = DirigeraClient(ip: ip, token: appState.accessToken)
                        for await event in client.eventStream() {
                            guard !isLoadingLights else { continue }
                            applyEvent(event)
                        }
                        print("[WS] Reconnecting in 5s…")
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
                Text("v\(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !appState.accessToken.isEmpty && isLoadingLights {
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

    // MARK: - Pairing

    @ViewBuilder
    private var pairingView: some View {
        switch pairingStep {
        case .idle:
            Text("Connect your Dirigera hub")
                .font(.headline)
            Text("The app will guide you through pairing. Keep your hub nearby — you'll need to press the button on top.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Start pairing") {
                    guard let ip = mdns.currentIPAddress else { return }
                    Task { await startPairing(ip: ip) }
                }
                .disabled(mdns.currentIPAddress == nil)
            }
            manualTokenEntry

        case .requesting:
            HStack(spacing: 8) {
                ProgressView()
                Text("Contacting hub…")
                    .foregroundStyle(.secondary)
            }

        case .awaitingButtonPress(let ip, let code, let verifier):
            Text("Press the button on top of your hub")
                .font(.headline)
            Text("Hold it for about 5 seconds until the light pulses, then tap the button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { pairingStep = .idle }
                Spacer()
                Button("I pressed it") {
                    Task { await finishPairing(ip: ip, code: code, verifier: verifier) }
                }
                .buttonStyle(.borderedProminent)
            }

        case .exchanging:
            HStack(spacing: 8) {
                ProgressView()
                Text("Completing pairing…")
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Try again") { pairingStep = .idle }
            }
            manualTokenEntry
        }
    }

    @ViewBuilder
    private var manualTokenEntry: some View {
        DisclosureGroup("Have a token? Enter it manually") {
            SecureField("Access Token", text: $tempToken)
                .textFieldStyle(.roundedBorder)
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
        .font(.caption)
    }

    private func startPairing(ip: String) async {
        pairingStep = .requesting
        do {
            let (code, verifier) = try await DirigeraAuthClient(ip: ip).requestPairing()
            pairingStep = .awaitingButtonPress(ip: ip, code: code, verifier: verifier)
        } catch {
            pairingStep = .failed("Couldn't reach the hub. Make sure you're on the same network.")
        }
    }

    private func finishPairing(ip: String, code: String, verifier: String) async {
        pairingStep = .exchanging
        do {
            let token = try await DirigeraAuthClient(ip: ip).exchangeToken(code: code, verifier: verifier)
            appState.accessToken = token
        } catch {
            pairingStep = .failed("Pairing failed. Did you press the button? Try again.")
        }
    }

    // MARK: - Lights

    @ViewBuilder
    private var lightsSection: some View {
        if lights.isEmpty {
            if isLoadingLights {
                Label("Loading lights…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if lightsError != nil {
                Label("Failed to load lights", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("No lights found", systemImage: "lightbulb.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(lights) { light in
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
        if !sensors.isEmpty {
            Divider()
            ForEach(sensors) { sensor in
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
        if !envSensors.isEmpty {
            Divider()
            ForEach(envSensors) { sensor in
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

    private func syncPinnedState() {
        guard let id = appState.pinnedLightId else { return }
        appState.pinnedLightIsOn = lights.first { $0.id == id }?.isOn ?? false
    }

    private func subtitle(room: String?, battery: Int?) -> String? {
        let parts = [room, battery.map { "\($0)% battery" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func applyEvent(_ event: DirigeraEvent) {
        guard event.isDeviceStateChanged,
              let data = event.data, let id = data.id else { return }
        if let i = lights.firstIndex(where: { $0.id == id }) {
            lights[i] = lights[i].merging(data)
            syncPinnedState()
        } else if let i = sensors.firstIndex(where: { $0.id == id }) {
            sensors[i] = sensors[i].merging(data)
        } else {
            let primaryId = envSensorIdMap[id] ?? id
            if let i = envSensors.firstIndex(where: { $0.id == primaryId }) {
                envSensors[i] = envSensors[i].merging(data)
            }
        }
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

    private func fetchDevices(ip: String) async {
        isLoadingLights = true
        lightsError = nil
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            let all = try await client.fetchAllDevices()
            gatewayName = all.first { $0.isGateway }?.displayName
            lights = all.filter { $0.isLight }
            sensors = all.filter { $0.isOpenCloseSensor }
            let (merged, idMap) = DirigeraDevice.mergeEnvSensors(all.filter { $0.isEnvironmentSensor })
            envSensors = merged
            envSensorIdMap = idMap
            print("[API] Fetched \(lights.count) light(s), \(sensors.count) sensor(s), \(envSensors.count) env sensor(s), gateway: \(gatewayName ?? "none")")
            syncPinnedState()
        } catch {
            lightsError = "Failed to load devices"
            print("[API] Fetch error: \(error)")
        }
        isLoadingLights = false
    }

    private func setBrightness(_ light: DirigeraDevice, to level: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        lights = lights.map { $0.id == light.id ? $0.withLightLevel(level) : $0 }
        pendingLightLevels[light.id] = nil
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setLightLevel(id: light.id, lightLevel: level)
        } catch {
            print("[API] Brightness error: \(error)")
        }
    }

    private func setColorTemperature(_ light: DirigeraDevice, to value: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        lights = lights.map { $0.id == light.id ? $0.withColorTemperature(value) : $0 }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setColorTemperature(id: light.id, colorTemperature: value)
        } catch {
            print("[API] Color temperature error: \(error)")
        }
    }

    private func setColor(_ light: DirigeraDevice, hue: Double, saturation: Double) async {
        guard let ip = mdns.currentIPAddress else { return }
        lights = lights.map { $0.id == light.id ? $0.withColor(hue: hue, saturation: saturation) : $0 }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setColor(id: light.id, hue: hue, saturation: saturation)
        } catch {
            print("[API] Color error: \(error)")
        }
    }

    private func toggleLight(_ light: DirigeraDevice) async {
        guard let ip = mdns.currentIPAddress else { return }
        toggleError = nil
        let newState = !light.isOn
        lights = lights.map { $0.id == light.id ? $0.withIsOn(newState) : $0 }
        syncPinnedState()
        isLoadingLights = true
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setLight(id: light.id, isOn: newState)
            await fetchDevices(ip: ip)
        } catch {
            lights = lights.map { $0.id == light.id ? $0.withIsOn(!newState) : $0 }
            isLoadingLights = false
            toggleError = "Failed to toggle \(light.displayName)"
            print("[API] Toggle error: \(error)")
        }
    }
}

#Preview {
    let state = AppState()
    MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}
