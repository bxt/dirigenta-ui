import OSLog

extension Logger {
    // The project sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which would
    // otherwise make these statics @MainActor and unreachable from Sendable
    // closures (e.g. NWBrowser handlers). Logger is Sendable and these are
    // immutable, so plain `nonisolated` is correct.
    nonisolated private static let subsystem =
        Bundle.main.bundleIdentifier ?? "dirigenta-ui"

    nonisolated static let api = Logger(subsystem: subsystem, category: "api")
    nonisolated static let webSocket = Logger(subsystem: subsystem, category: "websocket")
    nonisolated static let mdns = Logger(subsystem: subsystem, category: "mdns")
    nonisolated static let keychain = Logger(subsystem: subsystem, category: "keychain")
    nonisolated static let statusBar = Logger(subsystem: subsystem, category: "statusbar")
}
