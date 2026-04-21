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
                DispatchQueue.main.async { self?.isResolving = false }
            case .cancelled:
                DispatchQueue.main.async { self?.isResolving = false }
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
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            if let path = conn.currentPath,
               case let .hostPort(host, _) = path.remoteEndpoint {
                let ip = MDNSResolver.ipString(from: host)
                if !ip.isEmpty {
                    print("[mDNS] Resolved IP: \(ip)")
                    DispatchQueue.main.async {
                        self?.currentIPAddress = ip
                        self?.isResolving = false
                    }
                }
            }
            switch state {
            case .ready, .failed:
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
