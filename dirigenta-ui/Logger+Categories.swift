import OSLog

extension Logger {
    // Bundle.main is @MainActor-isolated in Swift 6, which would taint every
    // Logger category and prevent use from Sendable closures (e.g. NWBrowser
    // handlers). The statics are written once at load time and only ever read
    // afterward, so nonisolated(unsafe) is correct here.
    nonisolated(unsafe) private static let subsystem =
        Bundle.main.bundleIdentifier ?? "dirigenta-ui"

    nonisolated(unsafe) static let api = Logger(subsystem: subsystem, category: "api")
    nonisolated(unsafe) static let webSocket = Logger(subsystem: subsystem, category: "websocket")
    nonisolated(unsafe) static let mdns = Logger(subsystem: subsystem, category: "mdns")
    nonisolated(unsafe) static let keychain = Logger(subsystem: subsystem, category: "keychain")
    nonisolated(unsafe) static let statusBar = Logger(subsystem: subsystem, category: "statusbar")
}
