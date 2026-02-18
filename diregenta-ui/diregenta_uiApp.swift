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

    var body: some Scene {
        // Menu bar extra adds an icon to the system status bar (macOS)
        MenuBarExtra("diregenta-ui", systemImage: "bolt.horizontal.circle") {
            MenuContent(accessToken: $accessToken)
        }
        .menuBarExtraStyle(.window)
        .task {
            do {
                if let token = try KeychainService.get("dirigeraAccessToken") {
                    accessToken = token
                }
            } catch {
                print("[Keychain] Load error: \(error)")
            }
        }
    }
}

private struct MenuContent: View {
    @Binding var accessToken: String
    @State private var tempToken: String = ""

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
        } else {
            Button {
                Task { await performRESTCall(with: accessToken) }
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
    }
}

// MARK: - Networking
private func performRESTCall(with token: String) async {
    // Replace with your endpoint
    guard let url = URL(string: "https://httpbin.org/get") else { return }
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

