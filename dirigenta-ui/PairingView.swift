import SwiftUI

private enum PairingStep {
    case idle
    case requesting
    case awaitingButtonPress(ip: String, code: String, verifier: String)
    case exchanging
    case failed(String)
}

struct PairingView: View {
    /// Optional callback invoked after a successful pair (OAuth or manual token
    /// entry). Used by the sheet-presented "Add Hub" flow to dismiss itself.
    let onPaired: (() -> Void)?

    /// When set, a successful pair updates this existing hub in place instead
    /// of adding a new one — used to recover a hub whose TLS certificate
    /// rotated (see `AppState.addOrUpdateHub(token:hubFingerprint:gatewayName:replacing:)`).
    let replacingHubID: UUID?

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    @State private var pairingStep: PairingStep = .idle
    @State private var tempToken: String = ""
    // Held across both OAuth steps so both requests share the same URLSession.
    // The fingerprint captured during step 1 is then pinned for step 2.
    @State private var authClient: DirigeraAuthClient?

    init(replacingHubID: UUID? = nil, onPaired: (() -> Void)? = nil) {
        self.replacingHubID = replacingHubID
        self.onPaired = onPaired
    }

    fileprivate init(
        initialPairingStep: PairingStep,
        replacingHubID: UUID? = nil,
        onPaired: (() -> Void)? = nil
    ) {
        self.replacingHubID = replacingHubID
        self.onPaired = onPaired
        _pairingStep = State(initialValue: initialPairingStep)
    }

    /// Picks an mDNS-discovered hub IP for pairing. Prefers an IP that
    /// doesn't match any paired hub's `lastKnownIP` so adding a second hub on
    /// the same LAN doesn't try to re-pair the first; falls back to the most
    /// recent discovered IP when every advertisement matches a paired hub
    /// (typical case: re-pairing the only hub).
    private var pairingTargetIP: String? {
        let pairedIPs = Set(appState.hubs.compactMap { $0.lastKnownIP })
        if let unpaired = mdns.discoveredHubs.first(where: {
            !pairedIPs.contains($0.ip)
        }) {
            return unpaired.ip
        }
        return mdns.discoveredHubs
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first?.ip
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
                    guard let ip = pairingTargetIP else { return }
                    Task { await startPairing(ip: ip) }
                }
                .disabled(pairingTargetIP == nil)
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
                Button("Cancel") {
                    authClient?.invalidate()
                    authClient = nil
                    pairingStep = .idle
                }
                Spacer()
                Button("I pressed it") {
                    Task {
                        await finishPairing(
                            ip: ip,
                            code: code,
                            verifier: verifier
                        )
                    }
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
                    let trimmed = tempToken.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !trimmed.isEmpty else { return }
                    appState.addOrUpdateHub(
                        token: trimmed,
                        hubFingerprint: nil,
                        gatewayName: nil,
                        replacing: replacingHubID
                    )
                    onPaired?()
                }
                .disabled(
                    tempToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
        }
        .font(.caption)
    }

    private func startPairing(ip: String) async {
        // Discard any leftover client from a previous attempt.
        authClient?.invalidate()
        authClient = DirigeraAuthClient(ip: ip)
        pairingStep = .requesting
        do {
            let (code, verifier) = try await authClient!.requestPairing()
            pairingStep = .awaitingButtonPress(
                ip: ip,
                code: code,
                verifier: verifier
            )
        } catch {
            authClient?.invalidate()
            authClient = nil
            // Only a real transport failure warrants the "same network" hint.
            // A `DirigeraAuthError.unexpectedStatus` means the hub answered and
            // rejected the request — it's reachable, so steering the user
            // toward their network would be misleading.
            let message: String
            if case DirigeraAuthError.unexpectedStatus(let code) = error {
                message =
                    "The hub rejected the pairing request (HTTP \(code))."
            } else {
                message =
                    "Couldn't reach the hub. Make sure you're on the same network."
            }
            pairingStep = .failed(message)
        }
    }

    private func finishPairing(ip: String, code: String, verifier: String) async
    {
        pairingStep = .exchanging
        do {
            // Reuse the client from startPairing: same session, same pinned leaf cert.
            let client = authClient ?? DirigeraAuthClient(ip: ip)
            let token = try await client.exchangeToken(
                code: code,
                verifier: verifier
            )
            let fingerprint = client.capturedFingerprint
            client.invalidate()
            authClient = nil
            appState.addOrUpdateHub(
                token: token,
                hubFingerprint: fingerprint?.base64EncodedString(),
                gatewayName: nil,
                replacing: replacingHubID
            )
            onPaired?()
        } catch {
            authClient?.invalidate()
            authClient = nil
            pairingStep = .failed(
                "Pairing failed. Did you press the button? Try again."
            )
        }
    }
}

#Preview("Pairing — idle") {
    let state = AppState.preview()
    state.hubs = []
    state.mdns.discoveredHubs = [
        DiscoveredHub(
            ip: "192.168.1.100",
            serviceName: "Dirigera-Preview",
            lastSeenAt: Date()
        )
    ]
    return VStack(alignment: .leading, spacing: 8) { PairingView() }
        .padding(12)
        .frame(width: 300)
        .environmentObject(state)
        .environmentObject(state.mdns)
}

#Preview("Pairing — requesting") {
    let state = AppState.preview()
    state.hubs = []
    state.mdns.discoveredHubs = [
        DiscoveredHub(
            ip: "192.168.1.100",
            serviceName: "Dirigera-Preview",
            lastSeenAt: Date()
        )
    ]
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
    state.hubs = []
    state.mdns.discoveredHubs = [
        DiscoveredHub(
            ip: "192.168.1.100",
            serviceName: "Dirigera-Preview",
            lastSeenAt: Date()
        )
    ]
    return VStack(alignment: .leading, spacing: 8) {
        PairingView(
            initialPairingStep: .awaitingButtonPress(
                ip: "192.168.1.100",
                code: "abc123",
                verifier: "xyz456"
            )
        )
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}

#Preview("Pairing — exchanging") {
    let state = AppState.preview()
    state.hubs = []
    state.mdns.discoveredHubs = [
        DiscoveredHub(
            ip: "192.168.1.100",
            serviceName: "Dirigera-Preview",
            lastSeenAt: Date()
        )
    ]
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
    state.hubs = []
    state.mdns.discoveredHubs = [
        DiscoveredHub(
            ip: "192.168.1.100",
            serviceName: "Dirigera-Preview",
            lastSeenAt: Date()
        )
    ]
    return VStack(alignment: .leading, spacing: 8) {
        PairingView(
            initialPairingStep: .failed(
                "Pairing failed. Did you press the button? Try again."
            )
        )
    }
    .padding(12)
    .frame(width: 300)
    .environmentObject(state)
    .environmentObject(state.mdns)
}
