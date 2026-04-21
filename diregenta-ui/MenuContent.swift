
import SwiftUI
import AppKit

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
    @State private var gatewayName: String? = nil
    @State private var lights: [DirigeraDevice] = []
    @State private var sensors: [DirigeraDevice] = []
    @State private var envSensors: [DirigeraDevice] = []
    @State private var envSensorIdMap: [String: String] = [:]
    @State private var isLoadingLights = false
    @State private var lightsError: String? = nil
    @State private var toggleError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var now = Date()
    @EnvironmentObject private var mdns: MDNSResolver

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
                        let readings = envReadings(sensor)
                        if !readings.isEmpty {
                            readings.dropFirst().reduce(
                                Text(readings[0].text).foregroundStyle(readings[0].outOfRange ? Color.orange : Color.secondary)
                            ) { result, r in
                                result + Text(" · ").foregroundStyle(Color.secondary) + Text(r.text).foregroundStyle(r.outOfRange ? Color.orange : Color.secondary)
                            }
                            .font(.caption2)
                        }
                        if let sub = subtitle(room: sensor.room?.name, battery: sensor.attributes.batteryPercentage) {
                            Text(sub).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(isComfortable(sensor) ? Color.secondary : Color.yellow)
                }
            }
        }
    }

    private func syncPinnedState() {
        guard let id = appState.pinnedLightId else { return }
        appState.pinnedLightIsOn = lights.first { $0.id == id }?.isOn ?? false
    }

    private static func mergeEnvSensors(_ sensors: [DirigeraDevice]) -> ([DirigeraDevice], [String: String]) {
        var byRelation: [String: [DirigeraDevice]] = [:]
        var result: [DirigeraDevice] = []
        var idMap: [String: String] = [:]

        for sensor in sensors {
            if let rel = sensor.relationId {
                byRelation[rel, default: []].append(sensor)
            } else {
                result.append(sensor)
            }
        }

        for (_, group) in byRelation {
            // Sort so devices whose customName == model (generic default) come first;
            // the fold's last value wins, so the real user-set name ends up on top.
            let sorted = group.sorted { a, _ in a.attributes.customName == a.attributes.model }
            guard let first = sorted.first else { continue }
            let mergedAttrs = sorted.dropFirst().reduce(first.attributes) { $0.merging($1.attributes) }
            result.append(DirigeraDevice(
                id: first.id, type: first.type, deviceType: first.deviceType,
                relationId: first.relationId, isReachable: first.isReachable,
                lastSeen: first.lastSeen, room: first.room, attributes: mergedAttrs
            ))
            for sensor in sorted { idMap[sensor.id] = first.id }
        }

        return (result, idMap)
    }

    private func subtitle(room: String?, battery: Int?) -> String? {
        let parts = [room, battery.map { "\($0)% battery" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func applyEvent(_ event: DirigeraEvent) {
        guard event.type == "deviceStateChanged",
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

    private func openDuration(_ sensor: DirigeraDevice) -> String? {
        guard let raw = sensor.lastSeen else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: raw)
        }()
        guard let date else { return nil }
        let s = Int(now.timeIntervalSince(date))
        guard s > 0 else { return nil }
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    private func isComfortable(_ sensor: DirigeraDevice) -> Bool {
        envReadings(sensor).allSatisfy { !$0.outOfRange }
    }

    private struct Reading {
        let text: String
        let outOfRange: Bool
    }

    private func envReadings(_ sensor: DirigeraDevice) -> [Reading] {
        var parts: [Reading] = []
        if let t   = sensor.attributes.currentTemperature { parts.append(Reading(text: String(format: "%.1f°C", t),            outOfRange: !(18.0...26.0 ~= t))) }
        if let rh  = sensor.attributes.currentRH         { parts.append(Reading(text: String(format: "%.0f%% RH", rh),        outOfRange: !(30.0...60.0 ~= rh))) }
        if let co2 = sensor.attributes.currentCO2        { parts.append(Reading(text: String(format: "%.0f ppm CO₂", co2),    outOfRange: co2 > 1000)) }
        if let pm  = sensor.attributes.currentPM25       { parts.append(Reading(text: String(format: "%.0f µg/m³ PM2.5", pm), outOfRange: pm > 12)) }
        return parts
    }

    private func fetchDevices(ip: String) async {
        isLoadingLights = true
        lightsError = nil
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            let all = try await client.fetchAllDevices()
            gatewayName = all.first { $0.type == "gateway" }?.displayName
            lights = all.filter { $0.type == "light" }
            sensors = all.filter { $0.deviceType == "openCloseSensor" }
            let (merged, idMap) = Self.mergeEnvSensors(all.filter { $0.deviceType == "environmentSensor" })
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
