import AppKit
import OSLog
import SwiftUI

/// Banner shown above the hub content. The IP itself isn't surfaced here —
/// it's a per-hub diagnostic and lives in the Hubs section of Settings — so
/// users only see status (resolving, not found, or wrong-network) when
/// something is off. Hidden entirely once a connection is established or for
/// demo hubs (which bypass mDNS).
private struct DiscoveryStatusView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        Group {
            if let hub = appState.selectedHub, hub.kind == .demo {
                EmptyView()
            } else if appState.selectedHub == nil {
                // No paired hub — PairingView itself drives the discovery UX.
                EmptyView()
            } else if appState.currentHubIP != nil {
                EmptyView()
            } else if mdns.isResolving {
                Label("Discovering hub…", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if mdns.discoveredHubs.isEmpty {
                HStack(spacing: 4) {
                    Label(
                        "Hub not found",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Retry") { mdns.retry() }
                        .font(.caption)
                }
            } else {
                Label(
                    "Selected hub not on this network",
                    systemImage: "wifi.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
}

/// Header dropdown that lets the user switch between paired hubs, add a new
/// one, or jump to the Hubs section in Settings. Only shown when at least one
/// hub is paired — first-launch / fully-cleared state still goes through
/// `PairingView`.
private struct HubSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showingAddHub: Bool

    var body: some View {
        Menu {
            ForEach(appState.hubs) { hub in
                Button {
                    if hub.id != appState.selectedHubID {
                        appState.switchHub(to: hub.id)
                    }
                } label: {
                    Label {
                        Text(hub.displayName)
                    } icon: {
                        if hub.id == appState.selectedHubID {
                            Image(systemName: "checkmark")
                        } else if hub.kind == .demo {
                            Image(systemName: "play.tv")
                        }
                    }
                }
            }
            Divider()
            Button("Add Hub…") { showingAddHub = true }
            SettingsLink {
                Text("Manage Hubs…")
            }
        } label: {
            HStack(spacing: 4) {
                Text(headerTitle).font(.headline)
                if appState.selectedHub?.kind == .demo {
                    Image(systemName: "play.tv")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var headerTitle: String {
        if let hub = appState.selectedHub {
            // Prefer the live gateway name once we've fetched devices, since
            // it's authoritative. Fall back to the user-stored display name.
            return appState.gatewayName ?? hub.displayName
        }
        return "Dirigenta"
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

enum MenuTab: String { case devices, rooms, pinnedRoom }

struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var now = Date()
    @State private var wsRetry = 0
    @State private var currentScreen: NSScreen? = NSScreen.main
    @State private var contentHeight: CGFloat = 0
    @State private var showingAddHub = false
    @AppStorage("settings.defaultTab") private var selectedTab: MenuTab =
        .devices

    init() {}

    private var pinnedRoomId: String { appState.pinnedRoomId ?? "" }

    private var pinnedRoomName: String? {
        guard !pinnedRoomId.isEmpty else { return nil }
        return (appState.lights + appState.sensors + appState.envSensors)
            .first { $0.room?.id == pinnedRoomId }?.room?.name
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.hubs.isEmpty {
                HubSwitcherView(showingAddHub: $showingAddHub)
            }
            DiscoveryStatusView()
            Divider()
            if appState.selectedHub?.isReady != true {
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
                        Text("Devices").tag(MenuTab.devices)
                        Text("Rooms").tag(MenuTab.rooms)
                        if let name = pinnedRoomName {
                            Text(name).tag(MenuTab.pinnedRoom)
                        }
                    }
                    .pickerStyle(.segmented)

                    let screenHeight =
                        currentScreen?.visibleFrame.height ?? 8000
                    let maxHeight = screenHeight - 200
                    ScrollView {
                        Group {
                            if selectedTab == .devices {
                                DevicesView(now: now)
                            } else if selectedTab == .rooms {
                                RoomsView(now: now)
                            } else {
                                PinnedRoomView(roomId: pinnedRoomId, now: now)
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
                                    .onChange(of: geo.size.height) {
                                        _,
                                        newValue in
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
            Divider()
            HStack(spacing: 8) {
                Text("v\(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if appState.selectedHub?.isReady == true {
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
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { mdns.start() }
        .background(ScreenReader { currentScreen = $0 })
        .task(
            id:
                "\(appState.currentHubIP ?? ""):\(wsRetry):\(appState.wsRestartToken):\(appState.selectedHubID?.uuidString ?? ""):\(appState.selectedHub?.isReady == true)"
        ) {
            guard let ip = appState.currentHubIP,
                let client = appState.makeClient(ip: ip)
            else { return }
            await wsReconnectLoop(
                eventStream: { client.eventStream() },
                onConnecting: { appState.wsConnectionState = .connecting },
                onConnected: { appState.wsConnectionState = .connected },
                onEvent: { appState.applyEvent($0) },
                onDisconnected: { appState.wsConnectionState = .disconnected }
            )
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
        .onChange(of: pinnedRoomId) { _, newValue in
            if newValue.isEmpty && selectedTab == .pinnedRoom {
                selectedTab = .rooms
            }
        }
        .sheet(isPresented: $showingAddHub) {
            VStack(alignment: .leading, spacing: 8) {
                PairingView(onPaired: { showingAddHub = false })
                HStack {
                    Spacer()
                    Button("Cancel") { showingAddHub = false }
                }
            }
            .padding(16)
            .frame(width: 320)
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
    UserDefaults.standard.set(
        MenuTab.rooms.rawValue,
        forKey: "settings.defaultTab"
    )
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Discovering hub") {
    let state = AppState.preview()
    state.hubs = []
    state.mdns.isResolving = true
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Hub found — idle") {
    let state = AppState.preview()
    state.hubs = []
    state.mdns.discoveredHubs = [
        DiscoveredHub(
            ip: "192.168.1.100",
            serviceName: "Dirigera-Preview",
            lastSeenAt: Date()
        )
    ]
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Multiple hubs paired") {
    let state = AppState.preview()
    let cottage = Hub.real(
        displayName: "Cottage",
        accessToken: "tok-cottage"
    )
    state.hubs.append(cottage)
    return MenuContent()
        .environmentObject(state)
        .environmentObject(state.mdns)
}
