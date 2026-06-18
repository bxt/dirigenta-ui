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
            let device = appState.devices.first(where: { $0.id == id })
        {
            if device.isLight {
                name = device.lightIcon(isOn: appState.pinnedDeviceIsOn)
            } else if device.isSmartPlug {
                name = appState.pinnedDeviceIsOn
                    ? "poweroutlet.type.f.fill" : "poweroutlet.type.f"
            } else {
                name = appState.pinnedDeviceIsOn ? "lightbulb.fill" : "lightbulb"
            }
        } else if appState.pinnedDeviceId != nil {
            name = appState.pinnedDeviceIsOn ? "lightbulb.fill" : "lightbulb"
        } else {
            name = "house"
        }
        button.image = Self.menuBarIcon(named: name)
    }

    /// Renders an SF Symbol into a fixed-size square canvas (symbol scaled to
    /// fit, aspect preserved, centered) for the menu-bar button.
    ///
    /// The menu-bar icon must have *identical geometry* in every state. When a
    /// pinned light toggles, `updateIcon` swaps this image, and an `NSPopover`
    /// anchored to the status button repositions if the new image's size or
    /// alignment differs from the old — dragging the whole popover down a few
    /// pixels. Symbol bounding boxes vary between outline and filled variants
    /// (e.g. `lamp.ceiling` 16×18 vs `lamp.ceiling.fill` 15×17), so simply
    /// scaling the symbol isn't enough; only a constant canvas keeps the
    /// button's layout — and thus the popover — fixed. (Re-assigning an
    /// equally-sized image is already harmless, which is why toggling a
    /// non-pinned light never moved the popover.)
    private static func menuBarIcon(named name: String) -> NSImage? {
        guard
            let symbol = NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil
            )
        else { return nil }
        let canvas = NSSize(width: 18, height: 18)
        let scale = min(
            canvas.width / max(symbol.size.width, 1),
            canvas.height / max(symbol.size.height, 1)
        )
        let drawn = NSSize(
            width: symbol.size.width * scale,
            height: symbol.size.height * scale
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            symbol.draw(
                in: NSRect(
                    x: (canvas.width - drawn.width) / 2,
                    y: (canvas.height - drawn.height) / 2,
                    width: drawn.width,
                    height: drawn.height
                )
            )
            return true
        }
        image.isTemplate = true
        return image
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
            appState.popoverIsOpen = true
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
        appState.popoverIsOpen = false
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
        let device = appState.devices.first(where: { $0.id == deviceId })
        let newState = !appState.pinnedDeviceIsOn
        appState.pinnedDeviceIsOn = newState
        do {
            if let outletId = device?.attributes.outletId {
                try await client.setOutlet(id: outletId, isOn: newState)
            } else {
                try await client.setLight(id: deviceId, isOn: newState)
            }
        } catch {
            appState.pinnedDeviceIsOn = !newState
            Logger.statusBar.error(
                "Toggle error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
