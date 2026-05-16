import Foundation
import OSLog

/// In-memory `DirigeraClientProtocol` implementation backing the built-in
/// "Demo Hub". No network, no Keychain — a fixed device set plus a synthetic
/// event stream that toggles lights, flips sensors, and drifts the env-sensor
/// values on a timer so every UI surface (offline warning, room view,
/// environment panel, websocket-driven updates) is exercised without a real
/// hub. Used for QA, marketing screenshots, and onboarding.
@MainActor
final class DemoDirigeraClient: DirigeraClientProtocol {

    private var devices: [DirigeraDevice]
    private var continuations: [UUID: AsyncStream<DirigeraEvent>.Continuation] = [:]
    private var timerTask: Task<Void, Never>?

    init() {
        self.devices = Self.initialDevices()
    }

    // See `MDNSResolver` for why an explicit `nonisolated deinit` is needed.
    nonisolated deinit {}

    // MARK: - DirigeraClientProtocol

    nonisolated func fetchAllDevices() async throws -> [DirigeraDevice] {
        await Task.yield()  // simulate a tiny round-trip
        return await self.devices
    }

    nonisolated func setLight(id: String, isOn: Bool) async throws {
        await self.mutate(id: id) { $0.isOn = isOn }
    }

    nonisolated func setOutlet(id: String, isOn: Bool) async throws {
        await self.mutate(id: id) { $0.isOn = isOn }
    }

    nonisolated func setLightLevel(id: String, lightLevel: Int) async throws {
        await self.mutate(id: id) { $0.lightLevel = lightLevel }
    }

    nonisolated func setColor(id: String, hue: Double, saturation: Double) async throws {
        await self.mutate(id: id) {
            $0.colorHue = hue
            $0.colorSaturation = saturation
        }
    }

    nonisolated func setColorTemperature(id: String, colorTemperature: Int) async throws {
        await self.mutate(id: id) { $0.colorTemperature = colorTemperature }
    }

    nonisolated func applyColorPreset(
        _ preset: LightColorPreset,
        to id: String
    ) async throws {
        if let hue = preset.hue, let sat = preset.saturation {
            try await setColor(id: id, hue: hue, saturation: sat)
        } else if let ct = preset.colorTemperature {
            try await setColorTemperature(id: id, colorTemperature: ct)
        }
        if let level = preset.lightLevel {
            try await setLightLevel(id: id, lightLevel: level)
        }
    }

    nonisolated func eventStream() -> AsyncStream<DirigeraEvent> {
        AsyncStream { continuation in
            let token = UUID()
            Task { @MainActor in
                self.attachContinuation(continuation, token: token)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.detachContinuation(token: token)
                }
            }
        }
    }

    // MARK: - State mutation

    /// Applies `block` to the in-memory attributes for `id` and emits a
    /// `deviceStateChanged` event so subscribed UIs animate in response.
    private func mutate(
        id: String,
        _ block: (inout DirigeraDevice.Attributes) -> Void
    ) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        block(&devices[idx].attributes)
        emitStateChange(id: id, attributes: devices[idx].attributes)
    }

    private func emitStateChange(
        id: String,
        attributes: DirigeraDevice.Attributes
    ) {
        guard let event = makeStateChangeEvent(id: id, attributes: attributes)
        else { return }
        for c in continuations.values { c.yield(event) }
    }

    /// Builds a `DirigeraEvent` by encoding the attribute change to JSON and
    /// re-decoding it through the wire format. A bit roundabout, but it keeps
    /// `DirigeraEvent`'s init private (it's normally only constructed by the
    /// JSON decoder) and exercises the same decode path the real WebSocket uses.
    private func makeStateChangeEvent(
        id: String,
        attributes: DirigeraDevice.Attributes
    ) -> DirigeraEvent? {
        struct Payload: Encodable {
            let type: String
            let data: Body
            struct Body: Encodable {
                let id: String
                let attributes: DirigeraDevice.Attributes
            }
        }
        let payload = Payload(
            type: "deviceStateChanged",
            data: .init(id: id, attributes: attributes)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(DirigeraEvent.self, from: data)
    }

    private func attachContinuation(
        _ continuation: AsyncStream<DirigeraEvent>.Continuation,
        token: UUID
    ) {
        continuations[token] = continuation
        if timerTask == nil { startTimer() }
    }

    private func detachContinuation(token: UUID) {
        continuations.removeValue(forKey: token)
        if continuations.isEmpty {
            timerTask?.cancel()
            timerTask = nil
        }
    }

    // MARK: - Synthetic event timer
    //
    // Runs only while at least one consumer is subscribed to `eventStream()`,
    // so the demo doesn't keep the app awake when the popover is closed.

    private func startTimer() {
        timerTask = Task { @MainActor [weak self] in
            // Stagger phases (light toggle / sensor flip / env drift) so they
            // don't all fire at the same instant on launch.
            var lightAccum = 0
            var sensorAccum = 0
            var envAccum = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                lightAccum += 1
                sensorAccum += 1
                envAccum += 1
                if lightAccum >= 8 {
                    lightAccum = 0
                    self.toggleRandomLight()
                }
                if sensorAccum >= 30 {
                    sensorAccum = 0
                    self.flipRandomSensor()
                }
                if envAccum >= 60 {
                    envAccum = 0
                    self.driftEnvironmentSensor()
                }
            }
        }
    }

    private func toggleRandomLight() {
        let candidates = devices.indices.filter {
            devices[$0].isLight && devices[$0].isReachable != false
        }
        guard let idx = candidates.randomElement() else { return }
        let id = devices[idx].id
        let newState = !(devices[idx].attributes.isOn ?? false)
        mutate(id: id) { $0.isOn = newState }
    }

    private func flipRandomSensor() {
        let candidates = devices.indices.filter { devices[$0].isOpenCloseSensor }
        guard let idx = candidates.randomElement() else { return }
        let id = devices[idx].id
        let newOpen = !(devices[idx].attributes.isOpen ?? false)
        mutate(id: id) { $0.isOpen = newOpen }
    }

    private func driftEnvironmentSensor() {
        let candidates = devices.indices.filter {
            devices[$0].isEnvironmentSensor
        }
        guard let idx = candidates.randomElement() else { return }
        let id = devices[idx].id
        let tempDelta = Double.random(in: -0.3...0.3)
        let humidityDelta = Double(Int.random(in: -1...1))
        mutate(id: id) {
            if let t = $0.currentTemperature {
                $0.currentTemperature = ((t + tempDelta) * 10).rounded() / 10
            }
            if let rh = $0.currentRH {
                $0.currentRH = max(20, min(80, rh + humidityDelta))
            }
        }
    }

    // MARK: - Fixture devices

    private static func initialDevices() -> [DirigeraDevice] {
        let livingRoom = Room(id: "demo-r1", name: "Living Room")
        let kitchen = Room(id: "demo-r2", name: "Kitchen")
        let bedroom = Room(id: "demo-r3", name: "Bedroom")

        return [
            // Gateway — drives the displayed hub name once devices load.
            DirigeraDevice(
                id: "demo-gw",
                type: "gateway",
                attributes: .init(customName: "Demo Hub")
            ),

            // 6 lights across 3 rooms, including one offline bulb so the
            // unreachable warning (commit 027e5e4) shows in the demo.
            DirigeraDevice(
                id: "demo-l1",
                type: "light",
                isReachable: true,
                room: livingRoom,
                customIcon: "lighting_floor_lamp",
                attributes: .init(
                    customName: "Floor Lamp",
                    isOn: true,
                    lightLevel: 75,
                    colorTemperature: 2800,
                    colorTemperatureMin: 1801,
                    colorTemperatureMax: 6535
                )
            ),
            DirigeraDevice(
                id: "demo-l2",
                type: "light",
                isReachable: true,
                room: livingRoom,
                customIcon: "lighting_cone_pendant",
                attributes: .init(
                    customName: "Sofa Pendant",
                    isOn: false,
                    lightLevel: 100,
                    colorHue: 220,
                    colorSaturation: 0.6
                )
            ),
            DirigeraDevice(
                id: "demo-l3",
                type: "light",
                isReachable: true,
                room: kitchen,
                customIcon: "lighting_chandelier",
                attributes: .init(
                    customName: "Counter Light",
                    isOn: true,
                    lightLevel: 90,
                    colorTemperature: 4000,
                    colorTemperatureMin: 1801,
                    colorTemperatureMax: 6535
                )
            ),
            DirigeraDevice(
                id: "demo-l4",
                type: "light",
                isReachable: false,  // unreachable — drives offline warning
                lastSeen: ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(-3600)
                ),
                room: kitchen,
                attributes: .init(
                    customName: "Pantry Bulb",
                    isOn: false,
                    lightLevel: 100
                )
            ),
            DirigeraDevice(
                id: "demo-l5",
                type: "light",
                isReachable: true,
                room: bedroom,
                customIcon: "lighting_bulb",
                attributes: .init(
                    customName: "Bedside Lamp",
                    isOn: false,
                    lightLevel: 30,
                    colorTemperature: 2200,
                    colorTemperatureMin: 1801,
                    colorTemperatureMax: 6535
                )
            ),
            DirigeraDevice(
                id: "demo-l6",
                type: "light",
                isReachable: true,
                room: bedroom,
                customIcon: "lighting_pendant_lamp",
                attributes: .init(
                    customName: "Reading Light",
                    isOn: true,
                    lightLevel: 60,
                    colorTemperature: 3500,
                    colorTemperatureMin: 1801,
                    colorTemperatureMax: 6535
                )
            ),

            // Two open/close sensors so the window notifier has something to
            // toggle on the timer.
            DirigeraDevice(
                id: "demo-s1",
                type: "sensor",
                deviceType: "openCloseSensor",
                isReachable: true,
                room: livingRoom,
                customIcon: "placement_window",
                attributes: .init(
                    customName: "Living Room Window",
                    isOpen: false,
                    batteryPercentage: 78
                )
            ),
            DirigeraDevice(
                id: "demo-s2",
                type: "sensor",
                deviceType: "openCloseSensor",
                isReachable: true,
                room: kitchen,
                customIcon: "placement_window",
                attributes: .init(
                    customName: "Kitchen Door",
                    isOpen: true,
                    batteryPercentage: 35
                )
            ),

            // Environment sensor so the env panel renders.
            DirigeraDevice(
                id: "demo-env",
                type: "sensor",
                deviceType: "environmentSensor",
                isReachable: true,
                room: livingRoom,
                attributes: .init(
                    customName: "Air Quality",
                    currentTemperature: 21.5,
                    currentRH: 45,
                    currentCO2: 620,
                    currentPM25: 6
                )
            ),

            // Generic switch (1 component) so the merged-switch row in
            // otherDevices is exercised.
            DirigeraDevice(
                id: "demo-sw1",
                type: "controller",
                deviceType: "genericSwitch",
                relationId: "demo-sw-rel",
                isReachable: true,
                room: livingRoom,
                attributes: .init(
                    customName: "Living Room Remote",
                    batteryPercentage: 92,
                    switchGroup: 1
                )
            ),

            // Smart plug pair (outlet + meter) sharing a relationId so the
            // merge pipeline collapses them into one row with power readings.
            DirigeraDevice(
                id: "demo-p1-outlet",
                type: "outlet",
                deviceType: "outlet",
                relationId: "demo-plug-rel-1",
                isReachable: true,
                room: livingRoom,
                attributes: .init(
                    customName: "Coffee Maker",
                    isOn: true
                )
            ),
            DirigeraDevice(
                id: "demo-p1-meter",
                type: "outlet",
                relationId: "demo-plug-rel-1",
                isReachable: true,
                room: livingRoom,
                attributes: .init(
                    customName: "Coffee Maker",
                    currentActivePower: 87.3,
                    currentAmps: 0.395,
                    energyConsumedAtLastReset: 8400,
                    timeOfLastEnergyReset: "2025-01-15T10:30:00.000Z",
                    totalEnergyConsumed: 12450
                )
            ),

            // Motion sensor pair: lightSensor + occupancySensor sharing a
            // relationId. The merge folds illuminance and isDetected onto one
            // primary that renders inside the "Other devices" section as a
            // MotionSensorRow.
            DirigeraDevice(
                id: "demo-mot1_1",
                type: "unknown",
                deviceType: "lightSensor",
                relationId: "demo-mot1",
                isReachable: true,
                attributes: .init(
                    customName: "Bedroom Motion",
                    batteryPercentage: 88,
                    illuminance: 10792,
                    maxIlluminance: 40001,
                    minIlluminance: 1
                )
            ),
            DirigeraDevice(
                id: "demo-mot1_2",
                type: "sensor",
                deviceType: "occupancySensor",
                relationId: "demo-mot1",
                isReachable: true,
                room: bedroom,
                attributes: .init(
                    customName: "Bedroom Motion",
                    batteryPercentage: 88,
                    isDetected: false
                )
            ),

            // Water leak sensor under the kitchen sink. Single device, no
            // relation pairing. Starts dry so the notification path stays quiet
            // until the demo timer or a WebSocket event flips it.
            DirigeraDevice(
                id: "demo-water1",
                type: "sensor",
                deviceType: "waterSensor",
                isReachable: true,
                room: kitchen,
                customIcon: "products_matter_water_leak_sensor",
                attributes: .init(
                    customName: "Under Sink",
                    batteryPercentage: 92,
                    waterLeakDetected: false
                )
            ),
        ]
    }
}
