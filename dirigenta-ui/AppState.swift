import AppKit
import Combine
import Foundation
import OSLog

// Both the access token and hub TLS fingerprint are stored together in a single
// Keychain item so macOS only needs to prompt for access once.
private struct HubCredentials: Codable {
    var accessToken: String
    var hubFingerprint: String?  // base64-encoded SHA-256 of the hub's leaf TLS cert
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Persistence-backed state

    // SHA-256 fingerprint of the hub's TLS leaf certificate, stored in Keychain.
    // Set on first successful connection after pairing; required on all subsequent ones.
    private(set) var hubCertFingerprint: Data?

    @Published var accessToken: String {
        didSet {
            guard !Self.isPreview, accessToken != oldValue else { return }
            if accessToken.isEmpty {
                evictCachedClient()
                try? KeychainService.delete("dirigeraHub")
                hubCertFingerprint = nil
                clearDevices()
            } else {
                evictCachedClient()
                saveCredentials()
                // The Combine pipeline only fires when the IP changes, so if mDNS
                // already has a result (hub was found before the token was entered),
                // kick off a fetch manually.
                if let ip = mdns.currentIPAddress {
                    Task { await self.fetchDevices(ip: ip) }
                }
            }
        }
    }
    @Published var pinnedLightId: String? {
        didSet {
            guard !Self.isPreview else { return }
            UserDefaults.standard.set(pinnedLightId, forKey: "pinnedLightId")
        }
    }
    @Published var pinnedLightIsOn: Bool = false

    // MARK: - Device state

    enum WSConnectionState { case connecting, connected, disconnected }
    @Published var wsConnectionState: WSConnectionState = .connecting
    /// Bumped to force consumers (the WebSocket task in MenuContent) to tear
    /// down and re-establish their connection — used after wake-from-sleep,
    /// where TCP connections may be silently wedged.
    @Published var wsRestartToken: Int = 0

    @Published var gatewayName: String? = nil
    @Published var lights: [DirigeraDevice] = []
    @Published var sensors: [DirigeraDevice] = []
    @Published var envSensors: [DirigeraDevice] = []
    @Published var envSensorIdMap: [String: String] = [:]
    @Published var otherDevices: [DirigeraDevice] = []
    @Published var isLoadingDevices: Bool = false
    @Published var devicesError: String? = nil

    // MARK: - Infrastructure

    let mdns = MDNSResolver()
    private var cancellables: Set<AnyCancellable> = []

    // Cached client — reused across all requests as long as IP and token are stable.
    private var _cachedClient: DirigeraClient?
    private var _cachedClientIP: String = ""

    // MARK: - Init

    init() {
        if Self.isPreview {
            accessToken = ""
            pinnedLightId = nil
        } else {
            // Read token and hub fingerprint from the combined key (one Keychain prompt).
            if let raw = try? KeychainService.get("dirigeraHub"),
                let data = raw.data(using: .utf8),
                let creds = try? JSONDecoder().decode(
                    HubCredentials.self,
                    from: data
                )
            {
                accessToken = creds.accessToken
                hubCertFingerprint = creds.hubFingerprint.flatMap {
                    Data(base64Encoded: $0)
                }
            } else {
                accessToken = ""
            }
            pinnedLightId = UserDefaults.standard.string(
                forKey: "pinnedLightId"
            )
            // Auto-fetch whenever mDNS resolves a new IP and we have a token.
            mdns.$currentIPAddress
                .compactMap { $0 }
                .removeDuplicates()
                .sink { [weak self] ip in
                    Task { @MainActor [weak self] in
                        guard let self, !self.accessToken.isEmpty else { return }
                        await self.fetchDevices(ip: ip)
                    }
                }
                .store(in: &cancellables)
            // Recover from system sleep: TCP sockets often hang silently across
            // sleep/wake, mDNS state may be stale, and the WS retry budget may
            // already be exhausted. Force a clean refresh + reconnect on wake.
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.handleWake() }
                }
                .store(in: &cancellables)
        }
    }

    private func handleWake() {
        Logger.api.info("System woke from sleep — refreshing devices and reconnecting WebSocket")
        // Tear down the cached URLSession; its TCP connections may be wedged.
        evictCachedClient()
        // Bump the WS restart token so MenuContent's keyed .task tears down
        // and re-runs even when the IP hasn't changed.
        wsRestartToken &+= 1
        // Restart mDNS in case the laptop joined a different network or got
        // a new DHCP lease.
        mdns.stop()
        mdns.start()
        // mDNS only re-fires the auto-fetch sink when the IP changes
        // (removeDuplicates), so explicitly fetch with whatever IP we know.
        if let ip = mdns.currentIPAddress, !accessToken.isEmpty {
            Task { await self.fetchDevices(ip: ip) }
        }
    }

    // MARK: - Client factory

    /// Returns a cached `DirigeraClient` for the given IP, creating a new one only
    /// when the IP changes (or after a token / fingerprint change evicted the cache).
    /// Each `DirigeraClient` owns a `URLSession` with a TLS delegate; without caching
    /// every call-site would allocate a new session that is never invalidated.
    func makeClient(ip: String) -> DirigeraClient {
        if let cached = _cachedClient, _cachedClientIP == ip {
            return cached
        }
        _cachedClient?.invalidate()
        let client = DirigeraClient(
            ip: ip,
            token: accessToken,
            pinnedLeafFingerprint: hubCertFingerprint,
            onLeafFingerprint: hubCertFingerprint == nil
                ? { [weak self] fp in
                    Task { @MainActor [weak self] in
                        guard let self, self.hubCertFingerprint == nil else {
                            return
                        }
                        self.hubCertFingerprint = fp
                        self.saveCredentials()
                        // Evict so the next makeClient builds a session that pins
                        // the now-known fingerprint.
                        self.evictCachedClient()
                    }
                }
                : nil
        )
        _cachedClient = client
        _cachedClientIP = ip
        return client
    }

    private func evictCachedClient() {
        _cachedClient?.invalidate()
        _cachedClient = nil
        _cachedClientIP = ""
    }

    // MARK: - Device fetch & events

    func fetchDevices(ip: String, client injectedClient: (any DirigeraClientProtocol)? = nil) async {
        isLoadingDevices = true
        devicesError = nil
        let client: any DirigeraClientProtocol = injectedClient ?? makeClient(ip: ip)
        do {
            let all = try await client.fetchAllDevices()
            gatewayName = all.first { $0.isGateway }?.displayName
            lights = all.filter { $0.isLight }
            sensors = all.filter { $0.isOpenCloseSensor }
            let (merged, idMap) = DirigeraDevice.mergeEnvSensors(
                all.filter { $0.isEnvironmentSensor }
            )
            envSensors = merged
            envSensorIdMap = idMap
            otherDevices = all.filter {
                !$0.isLight && !$0.isGateway && !$0.isOpenCloseSensor && !$0.isEnvironmentSensor
            }
            let lc = lights.count
            let sc = sensors.count
            let ec = envSensors.count
            let gw = gatewayName ?? "none"
            Logger.api.info(
                "Fetched \(lc, privacy: .public) light(s), \(sc, privacy: .public) sensor(s), \(ec, privacy: .public) env sensor(s), gateway: \(gw, privacy: .public)"
            )
            syncPinnedState()
        } catch {
            devicesError = "Hub unreachable"
            Logger.api.error(
                "Fetch error: \(error.localizedDescription, privacy: .public)"
            )
        }
        isLoadingDevices = false
    }

    func applyEvent(_ event: DirigeraEvent) {
        guard event.isDeviceStateChanged,
            let data = event.data, let id = data.id
        else { return }
        if let i = lights.firstIndex(where: { $0.id == id }) {
            lights[i].merge(data)
            syncPinnedState()
        } else if let i = sensors.firstIndex(where: { $0.id == id }) {
            sensors[i].merge(data)
        } else {
            let primaryId = envSensorIdMap[id] ?? id
            if let i = envSensors.firstIndex(where: { $0.id == primaryId }) {
                envSensors[i].merge(data)
            }
        }
    }

    // MARK: - Light notification

    /// Flashes the pinned light (or all lights that are currently on) red for 1 second,
    /// then restores their previous state. Triggered by a --notify IPC invocation.
    func triggerNotification() async {
        guard let ip = mdns.currentIPAddress, !accessToken.isEmpty else { return }
        let client = makeClient(ip: ip)
        guard let notifier = LightNotifier(client: client, lights: lights, pinnedId: pinnedLightId)
        else { return }

        await notifier.turnOnDimmed()           // Step 2
        await fetchDevices(ip: ip)              // Step 3
        let presets = notifier.capturePresets(from: lights)  // Step 4
        await notifier.flash()                  // Step 5
        try? await Task.sleep(for: .seconds(1))
        await notifier.restore(presets)         // Step 6
        await notifier.turnOffDimmed()          // Step 7
        await fetchDevices(ip: ip)
    }

    /// Called by PairingView once both OAuth steps succeed.
    /// Storing the fingerprint before the token ensures a single Keychain write
    /// includes both, and that makeClient immediately builds a pinned session.
    func completePairing(token: String, hubFingerprint: Data?) {
        guard !Self.isPreview else { return }
        if let fp = hubFingerprint {
            hubCertFingerprint = fp
        }
        accessToken = token  // triggers didSet → evictCachedClient + saveCredentials + fetchDevices
    }

    func syncPinnedState() {
        guard let id = pinnedLightId else { return }
        pinnedLightIsOn = lights.first { $0.id == id }?.isOn ?? false
    }

    private func saveCredentials() {
        guard !Self.isPreview else { return }
        let creds = HubCredentials(
            accessToken: accessToken,
            hubFingerprint: hubCertFingerprint?.base64EncodedString()
        )
        guard let data = try? JSONEncoder().encode(creds),
            let str = String(data: data, encoding: .utf8)
        else { return }
        try? KeychainService.set(str, for: "dirigeraHub")
    }

    private func clearDevices() {
        lights = []
        sensors = []
        envSensors = []
        envSensorIdMap = [:]
        otherDevices = []
        gatewayName = nil
        devicesError = nil
    }

    // MARK: - Preview

    // Xcode sets this env var when running previews; used to skip Keychain/UserDefaults I/O.
    static let isPreview =
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    static func preview() -> AppState {
        let state = AppState()
        state.gatewayName = "My Smart Home"
        state.accessToken = "preview-token"
        state.lights = [
            DirigeraDevice(
                id: "ll1",
                type: "light",
                room: Room(id: "r1", name: "Living Room"),
                customIcon: "lighting_floor_lamp",
                attributes: .init(
                    customName: "Floor Lamp",
                    isOn: true,
                    lightLevel: 75,
                    colorTemperature: 3000,
                    colorTemperatureMin: 1801,
                    colorTemperatureMax: 6535
                )
            ),
            DirigeraDevice(
                id: "ll2",
                type: "light",
                room: Room(id: "r1", name: "Living Room"),
                customIcon: "lighting_cone_pendant",
                attributes: .init(
                    customName: "Ceiling Light",
                    isOn: false,
                    lightLevel: 100
                )
            ),
            DirigeraDevice(
                id: "ll3",
                type: "light",
                room: Room(id: "r2", name: "Kitchen"),
                customIcon: "lighting_chandelier",
                attributes: .init(
                    customName: "Ceiling Light",
                    isOn: false,
                    lightLevel: 100
                )
            ),
        ]
        state.sensors = [
            DirigeraDevice(
                id: "s1",
                type: "sensor",
                deviceType: "openCloseSensor",
                room: Room(id: "r1", name: "Living Room"),
                attributes: .init(
                    customName: "Window",
                    isOpen: true,
                    batteryPercentage: 20
                )
            ),
            DirigeraDevice(
                id: "s2",
                type: "sensor",
                deviceType: "openCloseSensor",
                room: Room(id: "r2", name: "Kitchen"),
                attributes: .init(
                    customName: "Window",
                    isOpen: false,
                    batteryPercentage: 85
                )
            ),
        ]
        state.otherDevices = [
            DirigeraDevice(
                id: "o1",
                type: "blinds",
                room: Room(id: "r2", name: "Bedroom"),
                attributes: .init(customName: "Bedroom Blinds", batteryPercentage: 72)
            ),
            DirigeraDevice(
                id: "o2",
                type: "speaker",
                attributes: .init(customName: "Kitchen Speaker")
            ),
        ]
        state.envSensors = [
            DirigeraDevice(
                id: "e1",
                type: "sensor",
                deviceType: "environmentSensor",
                room: Room(id: "r1", name: "Living Room"),
                attributes: .init(
                    customName: "Air Quality",
                    currentTemperature: 21.5,
                    currentRH: 45,
                    currentCO2: 650,
                    currentPM25: 5
                )
            ),
            DirigeraDevice(
                id: "e2",
                type: "sensor",
                deviceType: "environmentSensor",
                room: Room(id: "r1", name: "Living Room"),
                attributes: .init(
                    customName: "Air Quality Backup",
                    currentTemperature: 20.2,
                    currentRH: 43,
                    currentCO2: 652,
                    currentPM25: 4
                )
            ),
        ]
        return state
    }
}
