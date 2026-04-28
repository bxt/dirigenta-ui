import Combine
import Foundation
import Network

final class MDNSResolver: ObservableObject {
    @Published var currentIPAddress: String? = nil
    @Published var isResolving: Bool = false

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isResolving = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_ihsp._tcp.", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let result = results.first else { return }
            print("[mDNS] Found service: \(result.endpoint)")
            self.resolveEndpoint(result.endpoint)
        }

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[mDNS] Browser ready")
            case .failed(let error):
                print("[mDNS] Browser failed: \(error)")
                self?.isResolving = false
            case .cancelled:
                self?.isResolving = false
            default:
                break
            }
        }

        print("[mDNS] Starting browse for _ihsp._tcp. in local.")
        browser.start(queue: .main)
    }

    func stop() {
        print("[mDNS] Stopping browse")
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        isResolving = false
        hasStarted = false
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint) {
        connection?.cancel()

        // For Bonjour service endpoints, bypass NWConnection (which lets the OS pick
        // IPv6 when the hub advertises both) and use getaddrinfo with AF_INET instead.
        // On macOS, getaddrinfo routes .local lookups through mDNSResponder, so this
        // resolves via Bonjour just like NWConnection would, but IPv4-only.
        // The hostname is the service instance name + ".local" — standard Bonjour convention.
        if case .service(let name, _, _, _) = endpoint {
            resolveIPv4(hostname: "\(name).local", fallback: endpoint)
            return
        }

        openConnection(to: endpoint)
    }

    private func resolveIPv4(hostname: String, fallback: NWEndpoint) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM

            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(hostname, nil, &hints, &res) == 0, let res else {
                // No IPv4 address found; fall back to NWConnection (may return IPv6).
                DispatchQueue.main.async { self?.openConnection(to: fallback) }
                return
            }
            defer { freeaddrinfo(res) }

            var inAddr = res.pointee.ai_addr!
                .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)

            DispatchQueue.main.async { [weak self] in
                guard let self, !ip.isEmpty else { return }
                print("[mDNS] Resolved IPv4: \(ip)")
                self.currentIPAddress = ip
                self.isResolving = false
            }
        }
    }

    private func openConnection(to endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = conn.currentPath,
                   case let .hostPort(host, _) = path.remoteEndpoint {
                    let ip = MDNSResolver.ipString(from: host)
                    if !ip.isEmpty {
                        print("[mDNS] Resolved IP: \(ip)")
                        self?.currentIPAddress = ip
                        self?.isResolving = false
                    }
                }
                conn.cancel()
            case .failed:
                conn.cancel()
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
