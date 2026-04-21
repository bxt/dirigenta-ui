
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
    @Binding var accessToken: String
    @State private var tempToken: String = ""
    @State private var gatewayName: String? = nil
    @State private var lights: [DirigeraDevice] = []
    @State private var sensors: [DirigeraDevice] = []
    @State private var envSensors: [DirigeraDevice] = []
    @State private var envSensorIdMap: [String: String] = [:]
    @State private var isLoadingLights = false
    @State private var lightsError: String? = nil
    @State private var toggleError: String? = nil
    @State private var now = Date()
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if accessToken.isEmpty {
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
                            do {
                                try KeychainService.set(trimmed, for: "dirigeraAccessToken")
                                accessToken = trimmed
                            } catch {
                                print("[Keychain] Save error: \(error)")
                            }
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
                        let client = DirigeraClient(ip: ip, token: accessToken)
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
                if !accessToken.isEmpty && isLoadingLights {
                    Label("Refreshing…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !accessToken.isEmpty {
                    Button("Clear Token") {
                        do {
                            try KeychainService.delete("dirigeraAccessToken")
                        } catch {
                            print("[Keychain] Delete error: \(error)")
                        }
                        accessToken = ""
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
                            Text(readings)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
            guard let first = group.first else { continue }
            let mergedAttrs = group.dropFirst().reduce(first.attributes) { $0.merging($1.attributes) }
            result.append(DirigeraDevice(
                id: first.id, type: first.type, deviceType: first.deviceType,
                relationId: first.relationId, isReachable: first.isReachable,
                lastSeen: first.lastSeen, room: first.room, attributes: mergedAttrs
            ))
            for sensor in group { idMap[sensor.id] = first.id }
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
        let a = sensor.attributes
        if let t   = a.currentTemperature, !(18.0...26.0 ~= t)   { return false }
        if let rh  = a.currentRH,          !(30.0...60.0 ~= rh)  { return false }
        if let co2 = a.currentCO2,         co2 > 1000             { return false }
        if let pm  = a.currentPM25,        pm  > 12               { return false }
        return true
    }

    private func envReadings(_ sensor: DirigeraDevice) -> String {
        var parts: [String] = []
        if let t = sensor.attributes.currentTemperature { parts.append(String(format: "%.1f°C", t)) }
        if let rh = sensor.attributes.currentRH         { parts.append(String(format: "%.0f%% RH", rh)) }
        if let co2 = sensor.attributes.currentCO2       { parts.append(String(format: "%.0f ppm CO₂", co2)) }
        if let pm = sensor.attributes.currentPM25       { parts.append(String(format: "%.0f µg/m³ PM2.5", pm)) }
        return parts.joined(separator: " · ")
    }

    private func fetchDevices(ip: String) async {
        isLoadingLights = true
        lightsError = nil
        let client = DirigeraClient(ip: ip, token: accessToken)
        do {
            let all = try await client.fetchAllDevices()
            gatewayName = all.first { $0.type == "gateway" }?.displayName
            lights = all.filter { $0.type == "light" }
            sensors = all.filter { $0.deviceType == "openCloseSensor" }
            let (merged, idMap) = Self.mergeEnvSensors(all.filter { $0.deviceType == "environmentSensor" })
            envSensors = merged
            envSensorIdMap = idMap
            print("[API] Fetched \(lights.count) light(s), \(sensors.count) sensor(s), \(envSensors.count) env sensor(s), gateway: \(gatewayName ?? "none")")
        } catch {
            lightsError = "Failed to load devices"
            print("[API] Fetch error: \(error)")
        }
        isLoadingLights = false
    }

    private func toggleLight(_ light: DirigeraDevice) async {
        guard let ip = mdns.currentIPAddress else { return }
        toggleError = nil
        let newState = !light.isOn
        lights = lights.map { $0.id == light.id ? $0.withIsOn(newState) : $0 }
        isLoadingLights = true
        let client = DirigeraClient(ip: ip, token: accessToken)
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
    @Previewable @State var accessToken = "foo"
    MenuContent(accessToken: $accessToken)
}
