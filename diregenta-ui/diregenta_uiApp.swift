//
//  diregenta_uiApp.swift
//  diregenta-ui
//
//  Created by Bernhard Häussner on 18.02.26.
//

import SwiftUI

@main
struct diregenta_uiApp: App {
    @State private var accessToken: String = ""
    @StateObject private var mdns = MDNSResolver()

    var body: some Scene {
        MenuBarExtra("diregenta-ui", systemImage: "house") {
            MenuContent(accessToken: $accessToken)
                .environmentObject(mdns)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Networking
private func performRESTCall(with token: String, ip: String) async {
    print("[REST] Calling...")
    let host: String = "gw2-b63aaebc8948-2" // ip.contains(":") ? "[\(ip)]" : ip
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

