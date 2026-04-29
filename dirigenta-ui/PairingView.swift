import SwiftUI

private enum PairingStep {
    case idle
    case requesting
    case awaitingButtonPress(ip: String, code: String, verifier: String)
    case exchanging
    case failed(String)
}

struct PairingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var pairingStep: PairingStep = .idle
    @State private var tempToken: String = ""

    init() {}

    fileprivate init(initialPairingStep: PairingStep) {
        _pairingStep = State(initialValue: initialPairingStep)
    }

    var body: some View {
        switch pairingStep {
        case .idle:
            Text("Connect your Dirigera hub")
                .font(.headline)
            Text(
                "The app will guide you through pairing. Keep your hub nearby — you'll need to press the button on top."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Start pairing") {
                    guard let ip = mdns.currentIPAddress else { return }
                    Task { await startPairing(ip: ip) }
                }
                .disabled(mdns.currentIPAddress == nil)
            }
            manualTokenEntry

        case .requesting:
            HStack(spacing: 8) {
                ProgressView()
                Text("Contacting hub…")
                    .foregroundStyle(.secondary)
            }

        case .awaitingButtonPress(let ip, let code, let verifier):
            Text("Press the button on top of your hub")
                .font(.headline)
            Text(
                "Hold it for about 5 seconds until the light pulses, then tap the button below."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { pairingStep = .idle }
                Spacer()
                Button("I pressed it") {
                    Task { await finishPairing(ip: ip, code: code, verifier: verifier) }
                }
                .buttonStyle(.borderedProminent)
            }

        case .exchanging:
            HStack(spacing: 8) {
                ProgressView()
                Text("Completing pairing…")
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Try again") { pairingStep = .idle }
            }
            manualTokenEntry
        }
    }

    @ViewBuilder
    private var manualTokenEntry: some View {
        DisclosureGroup("Have a token? Enter it manually") {
            SecureField("Access Token", text: $tempToken)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Save") {
                    let trimmed = tempToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    appState.accessToken = trimmed
                }
                .disabled(tempToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.caption)
    }

    private func startPairing(ip: String) async {
        pairingStep = .requesting
        do {
            let (code, verifier) = try await DirigeraAuthClient(ip: ip).requestPairing()
            pairingStep = .awaitingButtonPress(ip: ip, code: code, verifier: verifier)
        } catch {
            pairingStep = .failed("Couldn't reach the hub. Make sure you're on the same network.")
        }
    }

    private func finishPairing(ip: String, code: String, verifier: String) async {
        pairingStep = .exchanging
        do {
            let token = try await DirigeraAuthClient(ip: ip).exchangeToken(
                code: code, verifier: verifier)
            appState.accessToken = token
        } catch {
            pairingStep = .failed("Pairing failed. Did you press the button? Try again.")
        }
    }
}

#Preview("Pairing — idle") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return VStack(alignment: .leading, spacing: 8) { PairingView() }
        .padding(12)
        .frame(width: 300)
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Pairing — requesting") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return VStack(alignment: .leading, spacing: 8) {
        PairingView(initialPairingStep: .requesting)
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}

#Preview("Pairing — awaiting button press") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return VStack(alignment: .leading, spacing: 8) {
        PairingView(
            initialPairingStep: .awaitingButtonPress(
                ip: "192.168.1.100", code: "abc123", verifier: "xyz456"))
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}

#Preview("Pairing — exchanging") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return VStack(alignment: .leading, spacing: 8) {
        PairingView(initialPairingStep: .exchanging)
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}

#Preview("Pairing — failed") {
    let state = AppState.preview()
    state.accessToken = ""
    state.mdns.currentIPAddress = "192.168.1.100"
    return VStack(alignment: .leading, spacing: 8) {
        PairingView(
            initialPairingStep: .failed(
                "Pairing failed. Did you press the button? Try again."))
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}
