import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "diregenta-ui"

    static let api       = Logger(subsystem: subsystem, category: "api")
    static let webSocket = Logger(subsystem: subsystem, category: "websocket")
    static let mdns      = Logger(subsystem: subsystem, category: "mdns")
    static let keychain  = Logger(subsystem: subsystem, category: "keychain")
    static let statusBar = Logger(subsystem: subsystem, category: "statusbar")
}
