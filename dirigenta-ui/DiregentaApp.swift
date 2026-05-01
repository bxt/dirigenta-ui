import SwiftUI
import UserNotifications

extension Notification.Name {
    /// Distributed notification posted by `--notify` invocations to trigger a light flash.
    /// Derived from the bundle identifier so it stays in sync if the app is renamed.
    static let dirigentaUINotify: Notification.Name = {
        guard let id = Bundle.main.bundleIdentifier else {
            preconditionFailure("Bundle identifier is missing — cannot construct IPC notification name")
        }
        return Notification.Name("\(id).notify")
    }()
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
    // lazy so it can reference appState and defer NSStatusBar access until
    // applicationDidFinishLaunching, when the app environment is fully ready.
    private lazy var statusBarController = StatusBarController(appState: appState)

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
        _ = statusBarController  // trigger lazy init
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
