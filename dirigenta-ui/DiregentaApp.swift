import OSLog
import SwiftUI
import UserNotifications

extension Notification.Name {
    /// Distributed notification posted by `--notify` invocations to trigger a light flash.
    /// Derived from the bundle identifier so it stays in sync if the app is renamed.
    static let dirigentaUINotify: Notification.Name = {
        guard let id = Bundle.main.bundleIdentifier else {
            preconditionFailure(
                "Bundle identifier is missing — cannot construct IPC notification name"
            )
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

class AppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    // Tests run inside this app as the test host. Without this guard the
    // stored-property default would build a real AppState (hitting Keychain)
    // and applicationDidFinishLaunching would spin up NWBrowser /
    // NWPathMonitor — both crash an unsigned CI binary.
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    lazy var appState = AppState()
    private lazy var statusBarController = StatusBarController(
        appState: appState
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // When invoked with --notify, post the distributed notification to the
        // already-running instance and exit — no UI needed.
        guard !CommandLine.arguments.contains("--notify") else {
            DistributedNotificationCenter.default().postNotificationName(
                .dirigentaUINotify,
                object: nil,
                deliverImmediately: true
            )
            // Brief run-loop spin so the notification is dispatched before exit.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            exit(0)
        }

        // Register defaults so UserDefaults.bool(forKey:) returns the right value
        // even before the user has opened Settings for the first time.
        UserDefaults.standard.register(defaults: [
            "settings.devices.showLights": true,
            "settings.devices.showEnvSensors": true,
            "settings.devices.showSensors": true,
            "settings.devices.showOtherDevices": true,
            "settings.rooms.showLights": true,
            "settings.rooms.showEnvSensors": true,
            "settings.rooms.showSensors": true,
            "settings.notifications.openWindow": true,
            "settings.notifications.closeWindow": true,
            "settings.notifications.waterLeak": true,
            "settings.notifications.ipc": true,
        ])

        // Become the notification delegate before launch completes so banners
        // present even while the app is frontmost — see willPresent below.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        NSApp.setActivationPolicy(.accessory)
        Self.logLaunchBanner()
        appState.mdns.start()
        _ = statusBarController  // trigger lazy init
        UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
        ]) { _, _ in }

        // Listen for notifications from --notify invocations.
        DistributedNotificationCenter.default().addObserver(
            forName: .dirigentaUINotify,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard
                UserDefaults.standard.bool(forKey: "settings.notifications.ipc")
            else { return }
            Task { await self.appState.triggerNotification() }
        }
    }

    // macOS drops notification banners while the posting app is frontmost — for
    // this menu-bar app that's whenever the popover is open, exactly when a
    // water-leak or window alert is most likely to fire. Returning presentation
    // options here forces the banner, sound, and Notification Center entry
    // regardless of activation state.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
    
    /// Logs a launch banner identifying the build and whether this is its
    /// first run, so a diagnostic log session can be matched to a release
    /// install — the only situation where the "hub discovered but devices
    /// never fetched" bug appears.
    private static func logLaunchBanner() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let current = "\(version) (\(build))"
        let previous = UserDefaults.standard.string(
            forKey: "diagnostics.lastRunVersion"
        )
        if previous != current {
            Logger.api.notice(
                "=== LAUNCH dirigenta-ui \(current, privacy: .public) — FIRST RUN OF THIS BUILD (previous: \(previous ?? "none", privacy: .public)) — macOS \(os, privacy: .public) ==="
            )
        } else {
            Logger.api.notice(
                "=== LAUNCH dirigenta-ui \(current, privacy: .public) — relaunch — macOS \(os, privacy: .public) ==="
            )
        }
        UserDefaults.standard.set(current, forKey: "diagnostics.lastRunVersion")
    }
}
