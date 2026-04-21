
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
    @State private var isLoadingLights = false
    @State private var lightsError: String? = nil
    @State private var toggleError: String? = nil
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
                    if isLoadingLights {
                        Label("Refreshing…", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Button("Clear Token") {
                        do {
                            try KeychainService.delete("dirigeraAccessToken")
                        } catch {
                            print("[Keychain] Delete error: \(error)")
                        }
                        accessToken = ""
                    }
                }
                .padding(8)
                .onAppear { mdns.start() }
                .task(id: mdns.currentIPAddress) {
                    guard let ip = mdns.currentIPAddress else { return }
                    await fetchDevices(ip: ip)
                }
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
                    Label(light.displayName, systemImage: light.isOn ? "lightbulb.fill" : "lightbulb")
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
                        if let pct = sensor.attributes.batteryPercentage {
                            Text("\(pct)% battery")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                        if let pct = sensor.attributes.batteryPercentage {
                            Text("\(pct)% battery")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(isComfortable(sensor) ? Color.secondary : Color.yellow)
                }
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
        let s = Int(Date().timeIntervalSince(date))
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
            envSensors = all.filter { $0.deviceType == "environmentSensor" }
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
