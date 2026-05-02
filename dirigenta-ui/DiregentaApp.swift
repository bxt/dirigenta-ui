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
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Tests run inside this app as the test host. Without this guard the
    // stored-property default would build a real AppState (hitting Keychain)
    // and applicationDidFinishLaunching would spin up NWBrowser /
    // NWPathMonitor — both crash an unsigned CI binary.
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    lazy var appState = AppState()
    private lazy var statusBarController = StatusBarController(appState: appState)

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
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

        // Register defaults so UserDefaults.bool(forKey:) returns the right value
        // even before the user has opened Settings for the first time.
        UserDefaults.standard.register(defaults: [
            "settings.defaultTab": MenuTab.devices.rawValue,
            "settings.devices.showLights": true,
            "settings.devices.showEnvSensors": true,
            "settings.devices.showSensors": true,
            "settings.devices.showOtherDevices": true,
            "settings.rooms.showLights": true,
            "settings.rooms.showEnvSensors": true,
            "settings.rooms.showSensors": true,
            "settings.notifications.openWindow": true,
            "settings.notifications.closeWindow": true,
            "settings.notifications.ipc": true,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
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
            guard UserDefaults.standard.bool(forKey: "settings.notifications.ipc") else { return }
            Task { await self.appState.triggerNotification() }
        }
    }
}
