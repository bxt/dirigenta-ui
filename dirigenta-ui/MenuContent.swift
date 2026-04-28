import AppKit
import OSLog
import SwiftUI

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

private struct FooterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScreenReader: NSViewRepresentable {
    let onScreen: (NSScreen) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let screen = view.window?.screen { onScreen(screen) }
        }
    }
}

private struct DeviceGroup: Identifiable {
    let id: String
    let roomName: String?
    let devices: [DirigeraDevice]
}

struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver
    @State private var tempToken: String = ""
    @State private var pairingStep: PairingStep = .idle
    @State private var actionError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil
    @State private var now = Date()
    @State private var wsRetry = 0
    @State private var currentScreen: NSScreen? = NSScreen.main
    @State private var footerHeight: CGFloat = 0

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
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
                    .onAppear { mdns.start() }
                    .task(id: "\(mdns.currentIPAddress ?? ""):\(wsRetry)") {
                        // AppState auto-fetches devices when the IP resolves.
                        // This task only maintains the WebSocket for live updates.
                        guard let ip = mdns.currentIPAddress else { return }
                        appState.wsConnectionState = .connecting
                        let maxRetries = 8
                        for attempt in 0...maxRetries {
                            if Task.isCancelled { break }
                            let client = DirigeraClient(
                                ip: ip,
                                token: appState.accessToken
                            )
                            for await event in client.eventStream() {
                                appState.wsConnectionState = .connected
                                guard !appState.isLoadingDevices else {
                                    continue
                                }
                                appState.applyEvent(event)
                            }
                            guard !Task.isCancelled else { break }
                            if attempt == maxRetries {
                                appState.wsConnectionState = .disconnected
                                break
                            }
                            appState.wsConnectionState = .connecting
                            let base = min(pow(2.0, Double(attempt)), 60.0)
                            let jitter = Double.random(
                                in: -0.25 * base...0.25 * base
                            )
                            let delay = max(1.0, base + jitter)
                            Logger.webSocket.info(
                                "Reconnecting in \(String(format: "%.1f", delay))s (attempt \(attempt + 1)/\(maxRetries))…"
                            )
                            try? await Task.sleep(for: .seconds(delay))
                        }
                    }
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            now = Date()
                        }
                    }
                    .frame(
                        maxHeight: {
                            let outerPadding: CGFloat = 12  // matches .padding(12) below
                            let footerSpacing: CGFloat = 8  // matches VStack spacing above
                            let screenHeight =
                                currentScreen?.visibleFrame.height ?? 800
                            return max(
                                100,
                                screenHeight - footerHeight - outerPadding * 2
                                    - footerSpacing
                            )
                        }()
                    )
                }
            }

            VStack(spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    Text("v\(appVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !appState.accessToken.isEmpty {
                        if appState.isLoadingDevices {
                            Label("Refreshing…", systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let error = appState.devicesError {
                            Label(
                                error,
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            switch appState.wsConnectionState {
                            case .connecting:
                                Label(
                                    "Connecting…",
                                    systemImage: "arrow.clockwise"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            case .disconnected:
                                Label("Disconnected", systemImage: "wifi.slash")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Button("Retry") { wsRetry += 1 }
                                    .font(.caption)
                            case .connected:
                                EmptyView()
                            }
                        }
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
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(ScreenReader { currentScreen = $0 })
    }

    // MARK: - Pairing

    @ViewBuilder
    private var pairingView: some View {
        switch pairingStep {
        case .idle:
            Text("Connect your Dirigera hub")
                .font(.headline)
            Text(
                "The app will guide you through pairing. Keep your hub nearby — you'll need to press the button on top."
            )
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
            Text(
                "Hold it for about 5 seconds until the light pulses, then tap the button below."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { pairingStep = .idle }
                Spacer()
                Button("I pressed it") {
                    Task {
                        await finishPairing(
                            ip: ip,
                            code: code,
                            verifier: verifier
                        )
                    }
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
                    let trimmed = tempToken.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !trimmed.isEmpty else { return }
                    appState.accessToken = trimmed
                }
                .disabled(
                    tempToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
        }
        .font(.caption)
    }

    private func startPairing(ip: String) async {
        pairingStep = .requesting
        do {
            let (code, verifier) = try await DirigeraAuthClient(ip: ip)
                .requestPairing()
            pairingStep = .awaitingButtonPress(
                ip: ip,
                code: code,
                verifier: verifier
            )
        } catch {
            pairingStep = .failed(
                "Couldn't reach the hub. Make sure you're on the same network."
            )
        }
    }

    private func finishPairing(ip: String, code: String, verifier: String) async
    {
        pairingStep = .exchanging
        do {
            let token = try await DirigeraAuthClient(ip: ip).exchangeToken(
                code: code,
                verifier: verifier
            )
            appState.accessToken = token
        } catch {
            pairingStep = .failed(
                "Pairing failed. Did you press the button? Try again."
            )
        }
    }

    // MARK: - Lights

    @ViewBuilder
    private var lightsSection: some View {
        if appState.lights.isEmpty {
            if appState.isLoadingDevices {
                Label("Loading lights…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = appState.devicesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("No lights found", systemImage: "lightbulb.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(grouped(appState.lights)) { group in
                if let name = group.roomName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                }
                ForEach(group.devices) { light in
                    HStack(spacing: 4) {
                        Button {
                            Task { await toggleLight(light) }
                        } label: {
                            Label(
                                light.displayName,
                                systemImage: light.isOn
                                    ? "lightbulb.fill" : "lightbulb"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if light.isOn && light.supportsColorControls {
                            Button {
                                colorPickerLightId =
                                    colorPickerLightId == light.id
                                    ? nil : light.id
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.caption)
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
                        Slider(
                            value: Binding(
                                get: {
                                    pendingLightLevels[light.id]
                                        ?? Double(level)
                                },
                                set: { pendingLightLevels[light.id] = $0 }
                            ),
                            in: 1...100
                        ) { editing in
                            if !editing,
                                let pending = pendingLightLevels[light.id]
                            {
                                Task {
                                    await setBrightness(light, to: Int(pending))
                                }
                            }
                        }
                        .padding(.leading, 22)
                        .padding(.trailing, 4)
                    }
                    if light.isOn && colorPickerLightId == light.id {
                        LightColorControls(
                            light: light,
                            onSetColorTemperature: { temp in
                                Task {
                                    await setColorTemperature(light, to: temp)
                                }
                            },
                            onSetColor: { hue, saturation in
                                Task {
                                    await setColor(
                                        light,
                                        hue: hue,
                                        saturation: saturation
                                    )
                                }
                            }
                        )
                    }
                }
            }
            if let error = actionError {
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
            ForEach(grouped(appState.sensors)) { group in
                if let name = group.roomName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                }
                ForEach(group.devices) { sensor in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sensor.displayName)
                            if sensor.isOpen,
                                let duration = openDuration(sensor)
                            {
                                Text("open for \(duration)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let sub = subtitle(
                                battery: sensor.attributes.batteryPercentage
                            ) {
                                Text(sub).font(.caption2).foregroundStyle(
                                    .secondary
                                )
                            }
                        }
                    } icon: {
                        Image(
                            systemName: sensor.isOpen
                                ? "sensor.tag.radiowaves.forward.fill"
                                : "sensor.fill"
                        )
                        .foregroundStyle(
                            sensor.isOpen ? Color.orange : Color.secondary
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var envSensorsSection: some View {
        if !appState.envSensors.isEmpty {
            Divider()
            ForEach(grouped(appState.envSensors)) { group in
                if let name = group.roomName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                }
                ForEach(group.devices) { sensor in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sensor.displayName)
                            let readings = sensor.envReadings
                            if !readings.isEmpty {
                                Text(
                                    readings.enumerated().reduce(
                                        into: AttributedString()
                                    ) { str, item in
                                        let (i, r) = item
                                        if i > 0 {
                                            str += AttributedString(" · ")
                                        }
                                        var part = AttributedString(r.text)
                                        if r.outOfRange {
                                            part.foregroundColor = .orange
                                        }
                                        str += part
                                    }
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            if let sub = subtitle(
                                battery: sensor.attributes.batteryPercentage
                            ) {
                                Text(sub).font(.caption2).foregroundStyle(
                                    .secondary
                                )
                            }
                        }
                    } icon: {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(
                                sensor.isComfortable
                                    ? Color.secondary : Color.yellow
                            )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func subtitle(battery: Int?) -> String? {
        battery.map { "\($0)% battery" }
    }

    private func grouped(_ devices: [DirigeraDevice]) -> [DeviceGroup] {
        var byRoom: [String: [DirigeraDevice]] = [:]
        var noRoom: [DirigeraDevice] = []
        for device in devices {
            if let name = device.room?.name {
                byRoom[name, default: []].append(device)
            } else {
                noRoom.append(device)
            }
        }
        var result = byRoom.keys.sorted().map {
            DeviceGroup(id: $0, roomName: $0, devices: byRoom[$0]!)
        }
        if !noRoom.isEmpty {
            result.append(DeviceGroup(id: "", roomName: nil, devices: noRoom))
        }
        return result
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
        let date =
            Self.isoWithFractional.date(from: raw)
            ?? Self.isoWithoutFractional.date(from: raw)
        guard let date else { return nil }
        let s = Int(now.timeIntervalSince(date))
        guard s > 0 else { return nil }
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    // MARK: - Light actions

    private func setBrightness(_ light: DirigeraDevice, to level: Int) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withLightLevel(level) : $0
        }
        pendingLightLevels[light.id] = nil
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setLightLevel(id: light.id, lightLevel: level)
        } catch {
            actionError = "Failed to set brightness for \(light.displayName)"
            Logger.api.error(
                "Brightness error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func setColorTemperature(_ light: DirigeraDevice, to value: Int)
        async
    {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withColorTemperature(value) : $0
        }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
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

    private func setColor(
        _ light: DirigeraDevice,
        hue: Double,
        saturation: Double
    ) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        appState.lights = appState.lights.map {
            $0.id == light.id
                ? $0.withColor(hue: hue, saturation: saturation) : $0
        }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
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

    private func toggleLight(_ light: DirigeraDevice) async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let newState = !light.isOn
        appState.lights = appState.lights.map {
            $0.id == light.id ? $0.withIsOn(newState) : $0
        }
        appState.syncPinnedState()
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
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
}

#Preview {
    let state = AppState.preview()
    MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}
