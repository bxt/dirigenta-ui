import AppKit
import SwiftUI

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

struct DevicesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var now = Date()
    @State private var currentScreen: NSScreen? = NSScreen.main
    @State private var contentHeight: CGFloat = 0
    @State private var selectedTab: Int = 0
    @State private var lightsExpanded: Bool = true
    @State private var envExpanded: Bool = true
    @State private var sensorsExpanded: Bool = true
    @State private var actionError: String? = nil
    @State private var pendingLightLevels: [String: Double] = [:]
    @State private var colorPickerLightId: String? = nil

    init() {}

    fileprivate init(initialTab: Int) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        content
            .background(ScreenReader { currentScreen = $0 })
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    now = Date()
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
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
                        VStack(alignment: .leading, spacing: 8) {
                            LightsSectionView(
                                lights: appState.lights,
                                isExpanded: $lightsExpanded,
                                pendingLightLevels: $pendingLightLevels,
                                colorPickerLightId: $colorPickerLightId,
                                actionError: $actionError,
                                showRoom: true,
                                onToggleAll: { await toggleAllLights() }
                            )
                            if !appState.envSensors.isEmpty {
                                Divider()
                                EnvSensorsSectionView(
                                    sensors: appState.envSensors,
                                    isExpanded: $envExpanded,
                                    showRoom: true
                                )
                            }
                            if !appState.sensors.isEmpty {
                                Divider()
                                OpenCloseSensorsSectionView(
                                    sensors: appState.sensors,
                                    now: now,
                                    isExpanded: $sensorsExpanded,
                                    showRoom: true
                                )
                            }
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

#Preview("Devices tab") {
    let state = AppState.preview()
    return VStack(alignment: .leading, spacing: 8) { DevicesView() }
        .padding(12)
        .frame(width: 300)
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Rooms tab") {
    let state = AppState.preview()
    return VStack(alignment: .leading, spacing: 8) {
        DevicesView(initialTab: 1)
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}
