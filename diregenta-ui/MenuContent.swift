
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
    @State private var lights: [DirigeraDevice] = []
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
                    DiscoveryStatusView()
                    Divider()
                    lightsSection
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
                    await fetchLights(ip: ip)
                }
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    @ViewBuilder
    private var lightsSection: some View {
        if isLoadingLights {
            Label("Loading lights…", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = lightsError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if lights.isEmpty {
            Label("No lights found", systemImage: "lightbulb.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func fetchLights(ip: String) async {
        isLoadingLights = true
        lightsError = nil
        let client = DirigeraClient(ip: ip, token: accessToken)
        do {
            lights = try await client.fetchLights()
            print("[API] Fetched \(lights.count) light(s)")
        } catch {
            lightsError = "Failed to load lights"
            print("[API] Fetch error: \(error)")
        }
        isLoadingLights = false
    }

    private func toggleLight(_ light: DirigeraDevice) async {
        guard let ip = mdns.currentIPAddress else { return }
        toggleError = nil
        let client = DirigeraClient(ip: ip, token: accessToken)
        do {
            try await client.setLight(id: light.id, isOn: !light.isOn)
            await fetchLights(ip: ip)
        } catch {
            toggleError = "Failed to toggle \(light.displayName)"
            print("[API] Toggle error: \(error)")
        }
    }
}

#Preview {
    @Previewable @State var accessToken = "foo"
    MenuContent(accessToken: $accessToken)
}
