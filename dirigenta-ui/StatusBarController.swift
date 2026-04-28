import AppKit
import Combine
import OSLog
import SwiftUI

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState!
    private var eventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func setup(appState: AppState) {
        self.appState = appState

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
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
        popover.contentViewController = NSHostingController(
            rootView: contentView
        )

        appState.$pinnedLightId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        appState.$pinnedLightIsOn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        appState.$lights
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        // AppState auto-fetches devices (including pinned light state) when mDNS
        // resolves, so no separate fetch is needed here.
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        if let id = appState.pinnedLightId,
            let light = appState.lights.first(where: { $0.id == id })
        {
            name = light.lightIcon(isOn: appState.pinnedLightIsOn)
        } else if appState.pinnedLightId != nil {
            name = appState.pinnedLightIsOn ? "lightbulb.fill" : "lightbulb"
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
        if event.type == .leftMouseDown, appState.pinnedLightId != nil,
            !popover.isShown
        {
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
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
                .leftMouseDown, .rightMouseDown,
            ]) { [weak self] _ in
                // Don't close while the system color panel is open — the user is
                // picking a colour and clicks there are expected outside the popover.
                guard !NSColorPanel.shared.isVisible else { return }
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        NSColorPanel.shared.orderOut(nil)  // dismiss colour panel together with popover
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func togglePinnedLight() async {
        guard let lightId = appState.pinnedLightId,
            let ip = appState.mdns.currentIPAddress
        else { return }
        let newState = !appState.pinnedLightIsOn
        appState.pinnedLightIsOn = newState
        let client = appState.makeClient(ip: ip)
        do {
            try await client.setLight(id: lightId, isOn: newState)
        } catch {
            appState.pinnedLightIsOn = !newState
            Logger.statusBar.error(
                "Toggle error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
