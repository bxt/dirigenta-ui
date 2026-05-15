import AppKit
import Combine
import OSLog
import SwiftUI

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let appState: AppState
    private var eventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

        let contentView = MenuContent()
            .environmentObject(appState)
            .environmentObject(appState.mdns)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(
            rootView: contentView
        )
        self.popover = popover

        super.init()

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.target = self
        }
        updateIcon()

        appState.$pinnedDeviceId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        appState.$pinnedDeviceIsOn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        appState.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        // AppState auto-fetches devices (including pinned-device state) when mDNS
        // resolves, so no separate fetch is needed here.
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        if let id = appState.pinnedDeviceId,
            let light = appState.devices.lights.first(where: { $0.id == id })
        {
            name = light.lightIcon(isOn: appState.pinnedDeviceIsOn)
        } else if appState.pinnedDeviceId != nil {
            name = appState.pinnedDeviceIsOn ? "lightbulb.fill" : "lightbulb"
        } else {
            name = "house"
        }
        button.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .leftMouseDown, appState.pinnedDeviceId != nil,
            !popover.isShown
        {
            Task { await togglePinnedDevice() }
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
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
                .leftMouseDown, .rightMouseDown,
            ]) { [weak self] _ in
                // Don't close while the system color panel is open — the user is
                // picking a color and clicks there are expected outside the popover.
                guard !NSColorPanel.shared.isVisible else { return }
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        NSColorPanel.shared.orderOut(nil)  // dismiss color panel together with popover
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func togglePinnedDevice() async {
        guard let deviceId = appState.pinnedDeviceId,
            let ip = appState.currentHubIP,
            let client = appState.makeClient(ip: ip)
        else { return }
        let newState = !appState.pinnedDeviceIsOn
        appState.pinnedDeviceIsOn = newState
        do {
            try await client.setLight(id: deviceId, isOn: newState)
        } catch {
            appState.pinnedDeviceIsOn = !newState
            Logger.statusBar.error(
                "Toggle error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
