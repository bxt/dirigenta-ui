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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        // Menu bar extra adds an icon to the system status bar (macOS)
        MenuBarExtra("diregenta-ui", systemImage: "bolt.horizontal.circle") {
            Button {
                Task { await performRESTCall() }
            } label: {
                Label("Perform REST Call", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}
// MARK: - Networking
private func performRESTCall() async {
    // Replace with your endpoint
    guard let url = URL(string: "https://httpbin.org/get") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

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

