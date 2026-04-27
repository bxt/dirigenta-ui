import Foundation
import Combine

final class AppState: ObservableObject {

    // MARK: - Persistence-backed state

    @Published var accessToken: String {
        didSet {
            guard !Self.isPreview else { return }
            do {
                if accessToken.isEmpty {
                    try KeychainService.delete("dirigeraAccessToken")
                    clearDevices()
                } else {
                    try KeychainService.set(accessToken, for: "dirigeraAccessToken")
                }
            } catch {
                print("[Keychain] Error: \(error)")
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
            accessToken = (try? KeychainService.get("dirigeraAccessToken")) ?? ""
            pinnedLightId = UserDefaults.standard.string(forKey: "pinnedLightId")
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

    // MARK: - Device fetch & events

    func fetchDevices(ip: String) async {
        isLoadingDevices = true
        devicesError = nil
        let client = DirigeraClient(ip: ip, token: accessToken)
        do {
            let all = try await client.fetchAllDevices()
            gatewayName = all.first { $0.isGateway }?.displayName
            lights = all.filter { $0.isLight }
            sensors = all.filter { $0.isOpenCloseSensor }
            let (merged, idMap) = DirigeraDevice.mergeEnvSensors(all.filter { $0.isEnvironmentSensor })
            envSensors = merged
            envSensorIdMap = idMap
            print("[API] Fetched \(lights.count) light(s), \(sensors.count) sensor(s), \(envSensors.count) env sensor(s), gateway: \(gatewayName ?? "none")")
            syncPinnedState()
        } catch {
            devicesError = "Failed to load devices"
            print("[API] Fetch error: \(error)")
        }
        isLoadingDevices = false
    }

    func applyEvent(_ event: DirigeraEvent) {
        guard event.isDeviceStateChanged,
              let data = event.data, let id = data.id else { return }
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

    func syncPinnedState() {
        guard let id = pinnedLightId else { return }
        pinnedLightIsOn = lights.first { $0.id == id }?.isOn ?? false
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
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    static func preview() -> AppState {
        let state = AppState()
        state.accessToken = "preview-token"
        state.lights = [
            DirigeraDevice(id: "l1", type: "light",
                           room: Room(id: "r1", name: "Living Room"),
                           attributes: .init(customName: "Floor Lamp", isOn: true, lightLevel: 75,
                                             colorTemperature: 3000,
                                             colorTemperatureMin: 1801, colorTemperatureMax: 6535)),
            DirigeraDevice(id: "l2", type: "light",
                           room: Room(id: "r1", name: "Living Room"),
                           attributes: .init(customName: "Ceiling Light", isOn: false, lightLevel: 100)),
        ]
        state.sensors = [
            DirigeraDevice(id: "s1", type: "sensor", deviceType: "openCloseSensor",
                           room: Room(id: "r2", name: "Kitchen"),
                           attributes: .init(customName: "Window", isOpen: false, batteryPercentage: 85)),
        ]
        state.envSensors = [
            DirigeraDevice(id: "e1", type: "sensor", deviceType: "environmentSensor",
                           room: Room(id: "r1", name: "Living Room"),
                           attributes: .init(customName: "Air Quality",
                                             currentTemperature: 21.5, currentRH: 45,
                                             currentCO2: 650, currentPM25: 5)),
        ]
        return state
    }
}
