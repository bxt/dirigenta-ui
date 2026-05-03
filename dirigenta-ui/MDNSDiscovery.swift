import Combine
import Foundation
import Network
import OSLog

@MainActor
final class MDNSResolver: ObservableObject {
    @Published var currentIPAddress: String? = nil
    @Published var isResolving: Bool = false

    private var browser: NWBrowser?
    private var connection: NWConnection?
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

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isResolving = true
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
        connection?.cancel()
        browser = nil
        connection = nil
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
        switch path.status {
        case .satisfied:
            browseAttempts = 0
            if currentIPAddress == nil { startBrowse() }
        case .unsatisfied, .requiresConnection:
            // Network gone — tear down sockets, keep "Discovering…" in the UI
            // (rather than "Hub not found") since we already know we can't.
            browser?.cancel()
            connection?.cancel()
            retryTask?.cancel()
            browser = nil
            connection = nil
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
            guard let self, let result = results.first else { return }
            Logger.mdns.info(
                "Found service: \(String(describing: result.endpoint), privacy: .public)"
            )
            // browser.start(queue: .main) guarantees this closure runs on the main
            // queue, so MainActor.assumeIsolated is safe here.
            MainActor.assumeIsolated {
                // Cancel the fallback retry — we have a result and are now
                // moving into the (potentially slow) resolve phase. The retry
                // would otherwise tear down the in-flight NWConnection.
                self.retryTask?.cancel()
                self.retryTask = nil
                self.resolveEndpoint(result.endpoint)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            // Same queue guarantee as above.
            switch state {
            case .ready:
                Logger.mdns.info("Browser ready")
            case .failed(let error):
                Logger.mdns.error(
                    "Browser failed: \(error.localizedDescription, privacy: .public) — will retry"
                )
                MainActor.assumeIsolated {
                    self?.scheduleBrowseRetry(after: .seconds(2))
                }
            case .cancelled:
                break
            default:
                break
            }
        }

        // Bonjour multicast responses are sometimes silently dropped on a
        // freshly joined network. If no result lands within a few seconds,
        // tear the browser down and try again.
        scheduleBrowseRetry(after: .seconds(5))

        Logger.mdns.info("Starting browse for _ihsp._tcp. in local.")
        browser.start(queue: .main)
    }

    private func scheduleBrowseRetry(after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.currentIPAddress == nil
            else { return }
            Logger.mdns.info("Retrying mDNS browse")
            self.startBrowse()
        }
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint) {
        connection?.cancel()
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            // conn.start(queue: .main) guarantees this closure runs on the main queue.
            switch state {
            case .ready:
                if let path = conn.currentPath,
                    case .hostPort(let host, _) = path.remoteEndpoint
                {
                    let ip = MDNSResolver.ipString(from: host)
                    if !ip.isEmpty {
                        Logger.mdns.info("Resolved IP: \(ip, privacy: .public)")
                        MainActor.assumeIsolated {
                            self?.currentIPAddress = ip
                            self?.isResolving = false
                            self?.retryTask?.cancel()
                            self?.retryTask = nil
                        }
                    }
                }
                conn.cancel()
            case .failed(let error):
                Logger.mdns.error(
                    "Resolve failed: \(error.localizedDescription, privacy: .public) — re-browsing"
                )
                conn.cancel()
                // The browse result may have been stale (host advertised but
                // unreachable). Re-browse to pick up a fresh endpoint.
                MainActor.assumeIsolated {
                    self?.scheduleBrowseRetry(after: .seconds(2))
                }
            default:
                break
            }
        }

        conn.start(queue: .main)
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
