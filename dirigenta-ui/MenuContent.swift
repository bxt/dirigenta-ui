import AppKit
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

// Reads the NSScreen the window is on; used to cap the scroll-view height.
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

    @State private var now = Date()
    @State private var wsRetry = 0
    @State private var currentScreen: NSScreen? = NSScreen.main
    @State private var contentHeight: CGFloat = 0
    @State private var selectedTab: Int = 0

    init() {}

    fileprivate init(initialTab: Int) {
        _selectedTab = State(initialValue: initialTab)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = appState.gatewayName {
                Text(name).font(.headline)
            }
            DiscoveryStatusView()
            Divider()
            if appState.accessToken.isEmpty {
                PairingView()
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

                    let screenHeight = currentScreen?.visibleFrame.height ?? 8000
                    let maxHeight = screenHeight - 200
                    ScrollView {
                        Group {
                            if selectedTab == 0 {
                                DevicesView(now: now)
                            } else {
                                RoomsView(now: now)
                            }
                        }
                        .frame(width: 276)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        DispatchQueue.main.async {
                                            contentHeight = geo.size.height
                                        }
                                    }
                                    .onChange(of: geo.size.height) { _, newValue in
                                        DispatchQueue.main.async {
                                            contentHeight = newValue
                                        }
                                    }
                            }
                        )
                    }
                    .frame(height: min(contentHeight, maxHeight))
                    .scrollDisabled(contentHeight < maxHeight)
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
        .background(ScreenReader { currentScreen = $0 })
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
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
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

#Preview("Normal — rooms tab") {
    let state = AppState.preview()
    return MenuContent(initialTab: 1)
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
