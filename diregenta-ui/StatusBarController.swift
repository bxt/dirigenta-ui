import AppKit
import SwiftUI
import Combine

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState!
    private var eventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func setup(appState: AppState) {
        self.appState = appState

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.target = self
        updateIcon()

        let contentView = MenuContent()
            .environmentObject(appState)
            .environmentObject(appState.mdns)
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: contentView)

        appState.$pinnedLightId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        appState.$pinnedLightIsOn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // Fetch pinned light state as soon as mDNS resolves so the icon
        // is correct on launch without the menu needing to be opened first.
        appState.mdns.$currentIPAddress
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] ip in
                guard let self, self.appState.pinnedLightId != nil else { return }
                Task { await self.fetchPinnedLightState(ip: ip) }
            }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        if appState.pinnedLightId != nil {
            name = appState.pinnedLightIsOn ? "lightbulb.fill" : "lightbulb"
        } else {
            name = "house"
        }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .leftMouseDown, appState.pinnedLightId != nil, !popover.isShown {
            Task { await togglePinnedLight() }
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            // Activate so that child panels (e.g. NSColorPanel) can become key.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                // Don't close while the system color panel is open — the user is
                // picking a colour and clicks there are expected outside the popover.
                guard !NSColorPanel.shared.isVisible else { return }
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        NSColorPanel.shared.orderOut(nil)   // dismiss colour panel together with popover
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func fetchPinnedLightState(ip: String) async {
        guard let lightId = appState.pinnedLightId else { return }
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            let devices = try await client.fetchAllDevices()
            if let light = devices.first(where: { $0.id == lightId }) {
                appState.pinnedLightIsOn = light.isOn
            }
        } catch {
            print("[StatusBar] Failed to fetch pinned light state: \(error)")
        }
    }

    private func togglePinnedLight() async {
        guard let lightId = appState.pinnedLightId,
              let ip = appState.mdns.currentIPAddress else { return }
        let newState = !appState.pinnedLightIsOn
        appState.pinnedLightIsOn = newState
        let client = DirigeraClient(ip: ip, token: appState.accessToken)
        do {
            try await client.setLight(id: lightId, isOn: newState)
        } catch {
            appState.pinnedLightIsOn = !newState
            print("[StatusBar] Toggle error: \(error)")
        }
    }
}
