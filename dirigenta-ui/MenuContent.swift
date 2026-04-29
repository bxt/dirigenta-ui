import OSLog
import SwiftUI

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
    @State private var wsRetry = 0

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
                PairingView()
            } else {
                DevicesView()
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
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            switch appState.wsConnectionState {
                            case .connecting:
                                Label("Connecting…", systemImage: "arrow.clockwise")
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
        .task(
            id: "\(mdns.currentIPAddress ?? ""):\(wsRetry):\(!appState.accessToken.isEmpty)"
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
