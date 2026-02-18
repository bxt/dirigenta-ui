//
//  diregenta_uiApp.swift
//  diregenta-ui
//
//  Created by Bernhard Häussner on 18.02.26.
//

import SwiftUI
import AppKit

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

private struct MenuContent: View {
    @Binding var accessToken: String
    @State private var tempToken: String = ""
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        if accessToken.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .onAppear { mdns.start() }
        }
    }
}

// MARK: - Networking
private func performRESTCall(with token: String, ip: String) async {
    guard let url = URL(string: "https://\(ip):8443/v1/devices") else { return }
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

    func start() {
        guard !isResolving else { return }
        isResolving = true
        browser.delegate = self
        services.removeAll()
        browser.searchForServices(ofType: "_ihsp._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        isResolving = false
    }
}

extension MDNSResolver: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Extract first IPv4 address
        guard let addresses = sender.addresses else { return }
        for addressData in addresses {
            let ipString = addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
                guard let sockaddrPointer = pointer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
                if sockaddrPointer.pointee.sa_family == sa_family_t(AF_INET) {
                    let addrIn = UnsafeRawPointer(sockaddrPointer).assumingMemoryBound(to: sockaddr_in.self).pointee
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addr = addrIn.sin_addr
                    inet_ntop(AF_INET, &addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                    return String(cString: ipBuffer)
                }
                return nil
            }
            if let ip = ipString {
                DispatchQueue.main.async {
                    self.currentIPAddress = ip
                    self.isResolving = false
                }
                stop()
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        DispatchQueue.main.async {
            self.isResolving = false
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async { self.isResolving = false }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        DispatchQueue.main.async { self.isResolving = false }
    }
}

