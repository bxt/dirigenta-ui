
import SwiftUI
import AppKit
import Combine

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

struct MenuContent: View {
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
                            print("Perform rest call here?")
                            guard let ip = mdns.currentIPAddress else { return }
                            // await performRESTCall(with: accessToken, ip: ip)
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


#Preview {
    @Previewable @State var accessToken = "foo"
    MenuContent(accessToken: $accessToken)
}
