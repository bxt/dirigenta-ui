import SwiftUI

extension Notification.Name {
    /// Distributed notification posted by `--notify` invocations to trigger a light flash.
    static let dirigentaUINotify = Notification.Name("dev.bxt.dirigenta-ui.notify")
}

@main
struct DirigentaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let statusBarController = StatusBarController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // When invoked with --notify, post the distributed notification to the
        // already-running instance and exit — no UI needed.
        guard !CommandLine.arguments.contains("--notify") else {
            DistributedNotificationCenter.default().postNotificationName(
                .dirigentaUINotify, object: nil, deliverImmediately: true
            )
            // Brief run-loop spin so the notification is dispatched before exit.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.mdns.start()
        statusBarController.setup(appState: appState)

        // Listen for notifications from --notify invocations.
        DistributedNotificationCenter.default().addObserver(
            forName: .dirigentaUINotify,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.appState.triggerNotification() }
        }
    }
}
