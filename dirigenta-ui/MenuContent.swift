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

private struct ScreenReader: NSViewRepresentable {
    let onScreen: (NSScreen) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let screen = view.window?.screen { onScreen(screen) }
        }
    }
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
    @State private var contentHeight: CGFloat = 0
    @State private var selectedTab: Int = 0
    @State private var devicesLightsExpanded: Bool = true
    @State private var devicesEnvExpanded: Bool = true
    @State private var devicesSensorsExpanded: Bool = true

    init() {}

    fileprivate init(initialPairingStep: PairingStep) {
        _pairingStep = State(initialValue: initialPairingStep)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = appState.gatewayName {
                Text(name)
                    .font(.headline)
            }
            DiscoveryStatusView()
            Divider()
            if appState.accessToken.isEmpty {
                pairingView
            } else {
                // Show a loading/error placeholder only on the very first fetch,
                // before any devices have arrived. Background refreshes (e.g. after
                // a toggle) leave the existing device data in place and are
                // indicated by the footer instead.
                let noDevicesYet =
                    appState.lights.isEmpty && appState.sensors.isEmpty
                    && appState.envSensors.isEmpty
                if noDevicesYet && appState.isLoadingDevices {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading devices…").foregroundStyle(.secondary)
                    }
                } else if noDevicesYet, let error = appState.devicesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Picker("", selection: $selectedTab) {
                        Text("Devices").tag(0)
                        Text("Rooms").tag(1)
                    }
                    .pickerStyle(.segmented)

                    let screenHeight =
                        currentScreen?.visibleFrame.height ?? 8000
                    let maxHeight = screenHeight - 200
                    ScrollView {
                        Group {
                            if selectedTab == 0 {
                                VStack(alignment: .leading, spacing: 8) {
                                    lightsSection
                                    sensorsSection
                                    envSensorsSection
                                }
                            } else {
                                RoomsView(now: now)
                            }
                        }
                        .frame(width: 276)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        contentHeight = geo.size.height
                                    }
                                    .onChange(of: geo.size.height) {
                                        oldValue,
                                        newValue in
                                        contentHeight = newValue
                                    }
                            }
                        )
                    }
                    .frame(height: min(contentHeight, maxHeight))
                    .scrollDisabled(contentHeight < maxHeight)
                }  // end devices-loaded else
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
        .onAppear { mdns.start() }
        .background(ScreenReader { currentScreen = $0 })
        .task(
            id:
                "\(mdns.currentIPAddress ?? ""):\(wsRetry):\(!appState.accessToken.isEmpty)"
        ) {
            guard let ip = mdns.currentIPAddress, !appState.accessToken.isEmpty
            else { return }
            appState.wsConnectionState = .connecting
            let maxRetries = 8
            for attempt in 0...maxRetries {
                if Task.isCancelled { break }
                let client = appState.makeClient(ip: ip)
                for await event in client.eventStream() {
                    appState.wsConnectionState = .connected
                    guard !appState.isLoadingDevices else { continue }
                    appState.applyEvent(event)
                }
                guard !Task.isCancelled else { break }
                if attempt == maxRetries {
                    appState.wsConnectionState = .disconnected
                    break
                }
                appState.wsConnectionState = .connecting
                let base = min(pow(2.0, Double(attempt)), 60.0)
                let jitter = Double.random(in: -0.25 * base...0.25 * base)
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

    // MARK: - Devices tab sections

    @ViewBuilder
    private var lightsSection: some View {
        if appState.lights.isEmpty {
            Label("No lights found", systemImage: "lightbulb.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let anyOn = appState.lights.contains { $0.isOn }
            let onCount = appState.lights.filter { $0.isOn }.count
            DisclosureGroup(isExpanded: $devicesLightsExpanded) {
                VStack(spacing: 8) {
                    ForEach(appState.lights) { light in
                        LightRowView(
                            light: light,
                            pendingLightLevels: $pendingLightLevels,
                            colorPickerLightId: $colorPickerLightId,
                            actionError: $actionError
                        )
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 10)
            } label: {
                Button {
                    Task { await toggleAllLights() }
                } label: {
                    Image(systemName: anyOn ? "lightbulb.fill" : "lightbulb")
                }
                .buttonStyle(.bordered)
                .help(anyOn ? "Turn all off" : "Turn all on")
                Text(
                    onCount > 0
                        ? "\(onCount) of \(appState.lights.count) on"
                        : "All off"
                )
                .foregroundStyle(.primary)
            }
            if let error = actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var envSensorsSection: some View {
        if !appState.envSensors.isEmpty {
            Divider()
            let avgReadings = DirigeraDevice.averagedEnvReadings(
                from: appState.envSensors
            )
            DisclosureGroup(isExpanded: $devicesEnvExpanded) {
                VStack(spacing: 8) {
                    ForEach(appState.envSensors) { sensor in
                        EnvSensorRow(sensor: sensor, showRoom: true)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 15)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(
                            avgReadings.allSatisfy { !$0.outOfRange }
                                ? Color.primary : Color.orange
                        )
                    EnvReadingsLine(readings: avgReadings, isHeadline: true)
                }
                .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private var sensorsSection: some View {
        if !appState.sensors.isEmpty {
            Divider()
            let anyOpen = appState.sensors.contains { $0.isOpen }
            let openCount = appState.sensors.filter { $0.isOpen }.count
            DisclosureGroup(isExpanded: $devicesSensorsExpanded) {
                VStack(spacing: 8) {
                    ForEach(appState.sensors) { sensor in
                        OpenCloseSensorRow(
                            sensor: sensor,
                            now: now,
                            showRoom: true
                        )
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: anyOpen
                            ? "sensor.tag.radiowaves.forward.fill"
                            : "sensor.fill"
                    )
                    .foregroundStyle(anyOpen ? Color.orange : Color.primary)
                    Text(
                        openCount > 0
                            ? "\(openCount) of \(appState.sensors.count) open"
                            : "All closed"
                    )
                    .foregroundStyle(
                        openCount > 0 ? Color.orange : Color.primary
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleAllLights() async {
        guard let ip = mdns.currentIPAddress else { return }
        actionError = nil
        let anyOn = appState.lights.contains { $0.isOn }
        let newState = !anyOn
        appState.lights = appState.lights.map { $0.withIsOn(newState) }
        appState.syncPinnedState()
        let client = appState.makeClient(ip: ip)
        await withTaskGroup(of: Void.self) { group in
            for light in appState.lights {
                group.addTask {
                    try? await client.setLight(id: light.id, isOn: newState)
                }
            }
        }
        await appState.fetchDevices(ip: ip)
    }
}

#Preview("Normal — with devices") {
    let state = AppState.preview()
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Discovering hub") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.isResolving = true
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Hub found — idle") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Pairing — requesting") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return MenuContent(initialPairingStep: .requesting)
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Pairing — awaiting button press") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return MenuContent(
        initialPairingStep: .awaitingButtonPress(
            ip: "192.168.1.100",
            code: "abc123",
            verifier: "xyz456"
        )
    )
    .environmentObject(state)
    .environmentObject(state.mdns)
}

#Preview("Pairing — exchanging") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return MenuContent(initialPairingStep: .exchanging)
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Pairing — failed") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return MenuContent(
        initialPairingStep: .failed(
            "Pairing failed. Did you press the button? Try again."
        )
    )
    .environmentObject(state)
    .environmentObject(state.mdns)
}
