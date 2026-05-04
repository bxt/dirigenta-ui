import Foundation

/// Orchestrates the flash-notification sequence:
/// turns target lights red for one second, then restores their previous state.
///
/// The caller is responsible for the two `fetchDevices` calls that bracket the
/// sequence (step 3 to read on-state color, and a final sync after restore),
/// since those belong to AppState, not to the notifier.
struct LightNotifier {
    private let client: any DirigeraClientProtocol
    /// Lights selected for the flash: the pinned light if one is set, otherwise
    /// all lights that were on at the time the notifier was created.
    let targets: [DirigeraDevice]
    /// On/off state of each target before anything was touched, used to restore
    /// lights that had to be turned on just to read their color.
    let wasOn: [String: Bool]

    /// Returns `nil` when there are no lights to flash.
    init?(
        client: any DirigeraClientProtocol,
        lights: [DirigeraDevice],
        pinnedId: String?
    ) {
        let targetLights: [DirigeraDevice]
        if let pinnedId, let pinned = lights.first(where: { $0.id == pinnedId })
        {
            targetLights = [pinned]
        } else {
            targetLights = lights.filter { $0.isOn }
        }
        guard !targetLights.isEmpty else { return nil }
        self.client = client
        self.targets = targetLights
        self.wasOn = Dictionary(
            uniqueKeysWithValues: targetLights.map { ($0.id, $0.isOn) }
        )
    }

    /// Step 2 — turns on any targets that were off so their color state can be read.
    func turnOnDimmed() async {
        await withTaskGroup(of: Void.self) { group in
            for (id, on) in wasOn where !on {
                group.addTask { try? await client.setLight(id: id, isOn: true) }
            }
        }
    }

    /// Step 4 — reads each target's current color/brightness from a freshly-fetched
    /// device list (call after `fetchDevices` so values reflect the on state).
    func capturePresets(from lights: [DirigeraDevice]) -> [(
        id: String, preset: LightColorPreset?
    )] {
        targets.compactMap { target in
            lights.first(where: { $0.id == target.id }).map {
                ($0.id, $0.colorPreset)
            }
        }
    }

    /// Step 5 — color lights go red at full saturation; all dimmable lights go to 100 %.
    func flash() async {
        await withTaskGroup(of: Void.self) { group in
            for t in targets {
                group.addTask {
                    if t.isColorLight {
                        try? await client.setColor(
                            id: t.id,
                            hue: 0,
                            saturation: 1
                        )
                    }
                    if t.attributes.lightLevel != nil {
                        try? await client.setLightLevel(
                            id: t.id,
                            lightLevel: 100
                        )
                    }
                }
            }
        }
    }

    /// Step 6 — restores each light to the preset captured in step 4.
    func restore(_ presets: [(id: String, preset: LightColorPreset?)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (id, preset) in presets {
                if let preset {
                    group.addTask {
                        try? await client.applyColorPreset(preset, to: id)
                    }
                }
            }
        }
    }

    /// Step 7 — turns off any lights that were originally off.
    func turnOffDimmed() async {
        await withTaskGroup(of: Void.self) { group in
            for (id, on) in wasOn where !on {
                group.addTask {
                    try? await client.setLight(id: id, isOn: false)
                }
            }
        }
    }
}
