import Combine
import Foundation
import Network
import OSLog

struct DiscoveredHub: Equatable {
    let ip: String
    let serviceName: String  // unique per hub instance (mDNS service name)
    var lastSeenAt: Date
}

@MainActor
final class MDNSResolver: ObservableObject {
    /// All hubs currently advertised on the LAN. We keep every entry rather
    /// than just the latest so a paired hub can be matched against its known
    /// fingerprint when more than one hub is reachable. Mutate via the browse
    /// callbacks; direct assignment is allowed for previews and tests.
    @Published var discoveredHubs: [DiscoveredHub] = []
    @Published var isResolving: Bool = false

    private var browser: NWBrowser?
    private var resolveConnections: [NWConnection] = []
    private var resolveTimeouts: [Task<Void, Never>] = []
    private var pathMonitor: NWPathMonitor?
    private var retryTask: Task<Void, Never>?
    private var hasStarted = false
    private var browseAttempts = 0
    private let maxBrowseAttempts = 5
    private let networkingEnabled: Bool

    /// - Parameter networkingEnabled: When `false`, `start()` only flips the
    ///   state machine (`isResolving`, `hasStarted`) without instantiating
    ///   `NWBrowser` / `NWPathMonitor`. Used in tests so an unsigned CI binary
    ///   never touches the Network framework (which can crash without the
    ///   right entitlements).
    init(networkingEnabled: Bool = true) {
        self.networkingEnabled = networkingEnabled
    }

    // The synthesized `@MainActor`-isolated deinit hops to the main actor via
    // `swift_task_deinitOnExecutorImpl`, which on the macos-26 CI runner
    // corrupts the task-local state and aborts inside libmalloc. Opting out
    // with `nonisolated deinit` skips that hop. Cleanup via `stop()` is the
    // caller's responsibility; the synthesized property releases are safe to
    // run without main-actor isolation.
    nonisolated deinit {}

    /// Best-effort IP for `hub` against the current `discoveredHubs`.
    /// See ``ip(forHub:in:)`` for the lookup rules.
    func ip(forHub hub: Hub) -> String? {
        Self.ip(forHub: hub, in: discoveredHubs)
    }

    /// Pure variant that runs the lookup against an explicit `hubs` snapshot.
    /// Used by the AppState Combine sink: `@Published`'s willSet semantics
    /// fire the publisher *before* the property is updated, so reading
    /// `self.discoveredHubs` from a `$discoveredHubs.sink` closure sees the
    /// stale (pre-assignment) value. Passing the publisher's emitted value
    /// directly avoids that race.
    /// - `kind == .demo` → the `"demo"` sentinel (never used for networking).
    /// - real hub with a `lastKnownIP` that's still being advertised → that IP.
    /// - real hub otherwise → the most recently discovered IP, or `nil` if
    ///   nothing is on the LAN.
    /// TLS pinning in `DirigeraClient` is what ultimately validates we're
    /// talking to the right hub when multiple are reachable.
    static func ip(forHub hub: Hub, in hubs: [DiscoveredHub]) -> String? {
        if hub.kind == .demo { return "demo" }
        if let last = hub.lastKnownIP,
            hubs.contains(where: { $0.ip == last })
        {
            return last
        }
        return hubs
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first?.ip
    }

    func start() {
        guard !hasStarted else {
            Logger.mdns.notice("start() — already started, ignoring")
            return
        }
        hasStarted = true
        isResolving = true
        Logger.mdns.notice(
            "start() — networkingEnabled=\(self.networkingEnabled, privacy: .public)"
        )
        guard networkingEnabled else { return }
        startPathMonitor()
    }

    func stop() {
        Logger.mdns.info("Stopping browse")
        retryTask?.cancel()
        retryTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        browser?.cancel()
        browser = nil
        cancelPendingResolves()
        discoveredHubs = []
        isResolving = false
        hasStarted = false
        browseAttempts = 0
    }

    func retry() {
        stop()
        start()
    }

    // MARK: - Path monitor

    /// Watches network reachability so we don't try to browse before the
    /// network is up — common when the app launches at login before Wi-Fi has
    /// associated. Once the path becomes satisfied, we kick off a browse.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // start(queue: .main) guarantees we're on the main queue here.
            MainActor.assumeIsolated { self?.handlePath(path) }
        }
        monitor.start(queue: .main)
    }

    private func handlePath(_ path: NWPath) {
        let interfaces = path.availableInterfaces
            .map { "\($0.type)" }
            .joined(separator: ",")
        Logger.mdns.notice(
            "path update — status=\(String(describing: path.status), privacy: .public), unsatisfiedReason=\(String(describing: path.unsatisfiedReason), privacy: .public), interfaces=[\(interfaces, privacy: .public)]"
        )
        switch path.status {
        case .satisfied:
            browseAttempts = 0
            if discoveredHubs.isEmpty {
                startBrowse()
            } else {
                Logger.mdns.notice(
                    "path satisfied — \(self.discoveredHubs.count, privacy: .public) hub(s) already discovered, not re-browsing"
                )
            }
        case .unsatisfied, .requiresConnection:
            // Network gone — tear down sockets, keep "Discovering…" in the UI
            // (rather than "Hub not found") since we already know we can't.
            browser?.cancel()
            cancelPendingResolves()
            retryTask?.cancel()
            browser = nil
            retryTask = nil
            isResolving = true
        @unknown default:
            break
        }
    }

    // MARK: - Browse

    private func startBrowse() {
        browseAttempts += 1
        if browseAttempts > maxBrowseAttempts {
            Logger.mdns.info("Max browse attempts reached — giving up")
            isResolving = false
            return
        }

        browser?.cancel()
        retryTask?.cancel()
        isResolving = true

        let descriptor = NWBrowser.Descriptor.bonjour(
            type: "_ihsp._tcp.",
            domain: "local."
        )
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // browser.start(queue: .main) guarantees this runs on the main queue.
            MainActor.assumeIsolated {
                self?.handleBrowseResults(Array(results))
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .setup:
                Logger.mdns.notice("Browser state: setup")
            case .ready:
                Logger.mdns.notice("Browser state: ready")
            case .waiting(let error):
                // A browser stuck in `.waiting` is the clearest signal of a
                // Local Network permission gate — the prime suspect for the
                // release-install bug.
                Logger.mdns.error(
                    "Browser state: waiting — \(error.localizedDescription, privacy: .public) (often a Local Network permission gate)"
                )
            case .failed(let error):
                Logger.mdns.error(
                    "Browser failed: \(error.localizedDescription, privacy: .public) — will retry"
                )
                MainActor.assumeIsolated {
                    self?.scheduleBrowseRetry(after: .seconds(2))
                }
            case .cancelled:
                Logger.mdns.notice("Browser state: cancelled")
            @unknown default:
                Logger.mdns.notice(
                    "Browser state: \(String(describing: state), privacy: .public)"
                )
            }
        }

        // Bonjour multicast responses are sometimes silently dropped on a
        // freshly joined network. If no result lands within a few seconds,
        // tear the browser down and try again.
        scheduleBrowseRetry(after: .seconds(5))

        Logger.mdns.info("Starting browse for _ihsp._tcp. in local.")
        browser.start(queue: .main)
    }

    private func handleBrowseResults(_ results: [NWBrowser.Result]) {
        retryTask?.cancel()
        retryTask = nil
        for result in results {
            let key = Self.serviceKey(for: result.endpoint)
            if let i = discoveredHubs.firstIndex(where: { $0.serviceName == key }) {
                discoveredHubs[i].lastSeenAt = Date()
            } else {
                Logger.mdns.info(
                    "Found service: \(String(describing: result.endpoint), privacy: .public)"
                )
                resolveEndpoint(result.endpoint, key: key)
            }
        }
    }

    private static func serviceKey(for endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return "\(endpoint)"
    }

    private func scheduleBrowseRetry(after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.discoveredHubs.isEmpty
            else { return }
            Logger.mdns.info("Retrying mDNS browse")
            self.startBrowse()
        }
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, key: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolveConnections.append(conn)

        // NWConnection has no built-in connect timeout. On the first launch
        // of a freshly installed (ad-hoc-signed) release the resolve can
        // stall indefinitely in `.preparing` while the system settles Local
        // Network permission for the new binary identity — the connection
        // reaches neither `.ready` nor `.failed`, so without this bound the
        // hub's IP is never resolved and the device fetch never fires.
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.handleResolveTimeout()
        }
        resolveTimeouts.append(timeout)

        conn.stateUpdateHandler = { [weak self] state in
            // conn.start(queue: .main) guarantees this closure runs on the main queue.
            switch state {
            case .setup:
                Logger.mdns.notice("Resolve conn state: setup")
            case .preparing:
                Logger.mdns.notice("Resolve conn state: preparing")
            case .waiting(let error):
                // Like the browser, a connection stuck in `.waiting` points at
                // a Local Network permission gate rather than a dead host.
                Logger.mdns.error(
                    "Resolve conn state: waiting — \(error.localizedDescription, privacy: .public) (often a Local Network permission gate)"
                )
            case .ready:
                timeout.cancel()
                if let path = conn.currentPath,
                    case .hostPort(let host, _) = path.remoteEndpoint
                {
                    let ip = MDNSResolver.ipString(from: host)
                    if !ip.isEmpty {
                        Logger.mdns.info("Resolved IP: \(ip, privacy: .public)")
                        MainActor.assumeIsolated {
                            self?.recordDiscovered(ip: ip, serviceName: key)
                        }
                    }
                }
                MainActor.assumeIsolated {
                    self?.removeResolveConnection(conn)
                }
                conn.cancel()
            case .failed(let error):
                timeout.cancel()
                Logger.mdns.error(
                    "Resolve failed: \(error.localizedDescription, privacy: .public) — re-browsing"
                )
                MainActor.assumeIsolated {
                    self?.removeResolveConnection(conn)
                    // The browse result may have been stale (host advertised but
                    // unreachable). Re-browse to pick up a fresh endpoint.
                    self?.scheduleBrowseRetry(after: .seconds(2))
                }
                conn.cancel()
            case .cancelled:
                timeout.cancel()
            @unknown default:
                break
            }
        }

        conn.start(queue: .main)
    }

    private func recordDiscovered(ip: String, serviceName: String) {
        if let i = discoveredHubs.firstIndex(where: { $0.serviceName == serviceName }) {
            discoveredHubs[i] = DiscoveredHub(
                ip: ip,
                serviceName: serviceName,
                lastSeenAt: Date()
            )
        } else {
            discoveredHubs.append(
                DiscoveredHub(
                    ip: ip,
                    serviceName: serviceName,
                    lastSeenAt: Date()
                )
            )
        }
        isResolving = false
        retryTask?.cancel()
        retryTask = nil
        Logger.mdns.notice(
            "recordDiscovered — ip=\(ip, privacy: .private) service=\(serviceName, privacy: .private); discoveredHubs now \(self.discoveredHubs.count, privacy: .public) — publisher will fire the AppState fetch sink"
        )
    }

    private func removeResolveConnection(_ conn: NWConnection) {
        resolveConnections.removeAll { $0 === conn }
    }

    /// Recovery for a resolve that never reached `.ready` or `.failed` — see
    /// `resolveEndpoint`. Tears down every pending resolve and re-browses,
    /// unless a hub has meanwhile been discovered.
    private func handleResolveTimeout() {
        guard discoveredHubs.isEmpty, !resolveConnections.isEmpty else { return }
        let states = resolveConnections
            .map { "\($0.state)" }
            .joined(separator: ",")
        Logger.mdns.error(
            "Resolve timed out (connection state(s): [\(states, privacy: .public)]) — cancelling and re-browsing"
        )
        cancelPendingResolves()
        scheduleBrowseRetry(after: .seconds(2))
    }

    /// Cancels every in-flight resolve — the `NWConnection`s and their
    /// timeout tasks. Used on teardown, network loss, and resolve timeout.
    private func cancelPendingResolves() {
        for conn in resolveConnections { conn.cancel() }
        resolveConnections.removeAll()
        for timeout in resolveTimeouts { timeout.cancel() }
        resolveTimeouts.removeAll()
    }

    nonisolated static func ipString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr):
            // Strip zone ID (e.g. "fe80::1%en0" → "fe80::1") and wrap in brackets
            // so the result is safe to embed in a URL (RFC 3986 §3.2.2).
            let base = "\(addr)".prefix(while: { $0 != "%" })
            return "[\(base)]"
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }
}
