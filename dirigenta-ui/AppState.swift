import Combine
import Foundation
import OSLog

// Both the access token and hub TLS fingerprint are stored together in a single
// Keychain item so macOS only needs to prompt for access once.
private struct HubCredentials: Codable {
    var accessToken: String
    var hubFingerprint: String?  // base64-encoded SHA-256 of the hub's leaf TLS cert
}

final class AppState: ObservableObject {

    // MARK: - Persistence-backed state

    // SHA-256 fingerprint of the hub's TLS leaf certificate, stored in Keychain.
    // Set on first successful connection after pairing; required on all subsequent ones.
    private(set) var hubCertFingerprint: Data?

    @Published var accessToken: String {
        didSet {
            guard !Self.isPreview else { return }
            if accessToken.isEmpty {
                try? KeychainService.delete("dirigeraHub")
                hubCertFingerprint = nil
                clearDevices()
            } else {
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

    @Published var gatewayName: String? = nil
    @Published var lights: [DirigeraDevice] = []
    @Published var sensors: [DirigeraDevice] = []
    @Published var envSensors: [DirigeraDevice] = []
    @Published var envSensorIdMap: [String: String] = [:]
    @Published var isLoadingDevices: Bool = false
    @Published var devicesError: String? = nil

    // MARK: - Infrastructure

    let mdns = MDNSResolver()
    private var cancellables: Set<AnyCancellable> = []

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
                    guard let self, !self.accessToken.isEmpty else { return }
                    Task { await self.fetchDevices(ip: ip) }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Client factory

    func makeClient(ip: String) -> DirigeraClient {
        DirigeraClient(
            ip: ip,
            token: accessToken,
            pinnedLeafFingerprint: hubCertFingerprint,
            onLeafFingerprint: hubCertFingerprint == nil
                ? { [weak self] fp in
                    DispatchQueue.main.async {
                        guard let self, self.hubCertFingerprint == nil else {
                            return
                        }
                        self.hubCertFingerprint = fp
                        self.saveCredentials()
                    }
                }
                : nil
        )
    }

    // MARK: - Device fetch & events

    func fetchDevices(ip: String) async {
        isLoadingDevices = true
        devicesError = nil
        let client = makeClient(ip: ip)
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
            lights[i] = lights[i].merging(data)
            syncPinnedState()
        } else if let i = sensors.firstIndex(where: { $0.id == id }) {
            sensors[i] = sensors[i].merging(data)
        } else {
            let primaryId = envSensorIdMap[id] ?? id
            if let i = envSensors.firstIndex(where: { $0.id == primaryId }) {
                envSensors[i] = envSensors[i].merging(data)
            }
        }
    }

    // MARK: - Light notification

    /// Flashes the pinned light (or all lights that are currently on) red for 1 second,
    /// then restores their previous state. Triggered by a --notify IPC invocation.
    func triggerNotification() async {
        guard let ip = mdns.currentIPAddress, !accessToken.isEmpty else { return }
        let client = makeClient(ip: ip)

        // Decide which lights to flash.
        let targetLights: [DirigeraDevice]
        if let pinnedId = pinnedLightId, let pinned = lights.first(where: { $0.id == pinnedId }) {
            targetLights = [pinned]
        } else {
            targetLights = lights.filter { $0.isOn }
        }
        guard !targetLights.isEmpty else { return }

        // Snapshot state so we can restore it afterwards.
        struct SavedState {
            let id: String
            let wasOn: Bool
            let lightLevel: Int?
            let colorHue: Double?
            let colorSaturation: Double?
            let colorTemperature: Int?
        }
        let saved = targetLights.map {
            SavedState(
                id: $0.id,
                wasOn: $0.isOn,
                lightLevel: $0.attributes.lightLevel,
                colorHue: $0.attributes.colorHue,
                colorSaturation: $0.attributes.colorSaturation,
                colorTemperature: $0.attributes.colorTemperature
            )
        }

        // Turn on (if needed) and flash red / max brightness.
        await withTaskGroup(of: Void.self) { group in
            for light in targetLights {
                group.addTask {
                    if !light.isOn {
                        try? await client.setLight(id: light.id, isOn: true)
                    }
                    if light.isColorLight {
                        try? await client.setColor(id: light.id, hue: 0, saturation: 1.0)
                    }
                    if light.attributes.lightLevel != nil {
                        try? await client.setLightLevel(id: light.id, lightLevel: 100)
                    }
                }
            }
        }

        try? await Task.sleep(for: .seconds(1))

        // Restore previous state.
        await withTaskGroup(of: Void.self) { group in
            for s in saved {
                group.addTask {
                    if !s.wasOn {
                        try? await client.setLight(id: s.id, isOn: false)
                    } else {
                        if let hue = s.colorHue, let sat = s.colorSaturation {
                            try? await client.setColor(id: s.id, hue: hue, saturation: sat)
                        } else if let ct = s.colorTemperature {
                            try? await client.setColorTemperature(id: s.id, colorTemperature: ct)
                        }
                        if let level = s.lightLevel {
                            try? await client.setLightLevel(id: s.id, lightLevel: level)
                        }
                    }
                }
            }
        }

        await fetchDevices(ip: ip)
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
