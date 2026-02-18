//
//  diregenta_uiApp.swift
//  diregenta-ui
//
//  Created by Bernhard Häussner on 18.02.26.
//

import SwiftUI
import AppKit
import Combine

@main
struct diregenta_uiApp: App {
    @State private var accessToken: String = ""
    @StateObject private var mdns = MDNSResolver()

    var body: some Scene {
        // Menu bar extra adds an icon to the system status bar (macOS)
        MenuBarExtra("diregenta-ui", systemImage: "bolt.horizontal.circle") {
            MenuContent(accessToken: $accessToken)
                .environmentObject(mdns)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct DiscoveryStatusView: View {
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        Group {
            if let ip = mdns.currentIPAddress {
                Label("Discovered IP: \(ip)", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if mdns.isResolving {
                Label("Discovering bridge…", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Bridge not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MenuContent: View {
    @Binding var accessToken: String
    @State private var tempToken: String = ""
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if accessToken.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DiscoveryStatusView()
                    Divider()
                    Text("Enter Dirigera Access Token")
                        .font(.headline)
                    SecureField("Access Token", text: $tempToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                    HStack {
                        Spacer()
                        Button("Save") {
                            let trimmed = tempToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            do {
                                try KeychainService.set(trimmed, for: "dirigeraAccessToken")
                                accessToken = trimmed
                            } catch {
                                print("[Keychain] Save error: \(error)")
                            }
                        }
                        .disabled(tempToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(8)
                .onAppear { mdns.start() }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    DiscoveryStatusView()
                    Divider()
                    Button {
                        Task {
                            guard let ip = mdns.currentIPAddress else { return }
                            await performRESTCall(with: accessToken, ip: ip)
                        }
                    } label: {
                        Label("Turn on light", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                    Button("Clear Token") {
                        do {
                            try KeychainService.delete("dirigeraAccessToken")
                        } catch {
                            print("[Keychain] Delete error: \(error)")
                        }
                        accessToken = ""
                    }
                }
                .onAppear { mdns.start() }
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

// MARK: - Networking
private func performRESTCall(with token: String, ip: String) async {
    let host: String = ip.contains(":") ? "[\(ip)]" : ip
    guard let url = URL(string: "https://\(host):8443/v1/devices") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            print("[REST] Status: \(http.statusCode)")
        }
        if let body = String(data: data, encoding: .utf8) {
            print("[REST] Body: \(body)")
        }
    } catch {
        print("[REST] Error: \(error)")
    }
}

// MARK: - mDNS Discovery
final class MDNSResolver: NSObject, ObservableObject {
    @Published var currentIPAddress: String? = nil
    @Published var isResolving: Bool = false

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isResolving = true
        browser.delegate = self
        services.removeAll()
        print("[mDNS] Starting browse for _ihsp._tcp. in local.")
        browser.searchForServices(ofType: "_ihsp._tcp.", inDomain: "local.")
    }

    func stop() {
        print("[mDNS] Stopping browse")
        browser.stop()
        isResolving = false
        hasStarted = false
    }
}

extension MDNSResolver: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("[mDNS] Will search…")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[mDNS] Found service: \(service.name)")
        services.append(service)
        service.includesPeerToPeer = true
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        print("[mDNS] Resolved: \(sender.name)")
        guard let addresses = sender.addresses, !addresses.isEmpty else {
            print("[mDNS] No addresses")
            return
        }

        // Prefer IPv4, fall back to IPv6 if needed
        if let ipv4 = addresses.compactMap({ Self.ipString(from: $0, preferIPv4: true) }).first {
            DispatchQueue.main.async {
                self.currentIPAddress = ipv4
                self.isResolving = false
            }
            print("[mDNS] Using IPv4: \(ipv4)")
            return
        }

        if let ipv6 = addresses.compactMap({ Self.ipString(from: $0, preferIPv4: false) }).first {
            DispatchQueue.main.async {
                self.currentIPAddress = ipv6
                self.isResolving = false
            }
            print("[mDNS] Using IPv6: \(ipv6)")
            return
        }

        print("[mDNS] Could not parse any IP addresses")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[mDNS] didNotResolve: \(errorDict)")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("[mDNS] Did stop search")
        DispatchQueue.main.async { self.isResolving = false }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("[mDNS] didNotSearch: \(errorDict)")
        DispatchQueue.main.async { self.isResolving = false }
    }

    private static func ipString(from addressData: Data, preferIPv4: Bool) -> String? {
        return addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
            guard let base = pointer.baseAddress else { return nil }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            if preferIPv4, family == sa_family_t(AF_INET) {
                let addrIn = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = addrIn.sin_addr
                inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buffer)
            } else if !preferIPv4, family == sa_family_t(AF_INET6) {
                let addrIn6 = base.assumingMemoryBound(to: sockaddr_in6.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var addr = addrIn6.sin6_addr
                inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                return String(cString: buffer)
            }
            return nil
        }
    }
}

