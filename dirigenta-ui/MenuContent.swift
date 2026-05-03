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
                HStack(spacing: 4) {
                    Label("Hub not found", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { mdns.retry() }
                        .font(.caption)
                }
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

enum MenuTab: String { case devices, rooms, pinnedRoom }

struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var now = Date()
    @State private var wsRetry = 0
    @State private var currentScreen: NSScreen? = NSScreen.main
    @State private var contentHeight: CGFloat = 0
    @AppStorage("settings.defaultTab") private var selectedTab: MenuTab =
        .devices
    @AppStorage("settings.pinnedRoomId") private var pinnedRoomId: String = ""

    init() {}

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
                "\(mdns.currentIPAddress ?? ""):\(wsRetry):\(appState.wsRestartToken):\(!appState.accessToken.isEmpty)"
        ) {
            guard let ip = mdns.currentIPAddress, !appState.accessToken.isEmpty
            else { return }
            await wsReconnectLoop(
                eventStream: { appState.makeClient(ip: ip).eventStream() },
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
