import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppState: ObservableObject {

    // MARK: - Persistence-backed state

    /// All paired hubs (real + demo). Persisted to Keychain as a JSON array.
    /// Mutate via `addOrUpdateHub` / `removeHub` so persistence stays in sync;
    /// direct assignment is allowed for previews and tests.
    @Published var hubs: [Hub] = []

    /// Identifier of the currently active hub. Persisted to UserDefaults
    /// (non-secret). Nil when no hub is paired — UI shows PairingView.
    /// Mutate via `switchHub` so device state and the cached client are reset;
    /// direct assignment is allowed for previews and tests.
    @Published var selectedHubID: UUID?

    /// Convenience lookup. `selectedHub` is the canonical "current context"
    /// — devices, websocket, pinned light/room are all scoped to it.
    var selectedHub: Hub? {
        guard let id = selectedHubID else { return nil }
        return hubs.first { $0.id == id }
    }

    /// IP we should use to talk to the selected hub right now. Nil when no
    /// hub is selected, or when a real selected hub isn't on the LAN.
    var currentHubIP: String? {
        selectedHub.flatMap { mdns.ip(forHub: $0) }
    }

    /// Pinned device id (light or smart plug), scoped to the selected hub.
    /// Mirrored from `selectedHub` so views and Combine subscribers can observe
    /// `$pinnedDeviceId` directly; writes are propagated back into the hub model.
    @Published var pinnedDeviceId: String? {
        didSet {
            guard !skipHubSync else { return }
            guard pinnedDeviceId != oldValue else { return }
            mutateSelectedHub { $0.pinnedDeviceId = pinnedDeviceId }
        }
    }

    /// Pinned room id, also scoped to the selected hub. Empty string is used
    /// as the "no pinned room" sentinel in views that read it as a `String`.
    @Published var pinnedRoomId: String? {
        didSet {
            guard !skipHubSync else { return }
            guard pinnedRoomId != oldValue else { return }
            mutateSelectedHub { $0.pinnedRoomId = pinnedRoomId }
        }
    }

    @Published var pinnedDeviceIsOn: Bool = false

    // MARK: - Device state

    enum WSConnectionState { case connecting, connected, disconnected }
    @Published var wsConnectionState: WSConnectionState = .connecting
    /// Bumped to force consumers (the WebSocket task in MenuContent) to tear
    /// down and re-establish their connection — used after wake-from-sleep,
    /// where TCP connections may be silently wedged.
    @Published var wsRestartToken: Int = 0

    @Published var gatewayName: String? = nil
    /// All visible devices in id-ascending order, with relationId-grouped
    /// components already merged into a single primary entry. Use the
    /// `[DirigeraDevice]` extension splitters (e.g. `appState.devices.lights`)
    /// to filter by type.
    @Published var devices: [DirigeraDevice] = []
    /// Maps every component id (including primaries) of any merged group to
    /// its primary device id, so WebSocket events targeting a component get
    /// routed to the correct merged entry. Devices outside any merged group
    /// are absent — call sites use `deviceIdMap[id] ?? id`.
    @Published var deviceIdMap: [String: String] = [:]
    @Published var isLoadingDevices: Bool = false
    @Published var devicesError: String? = nil

    // MARK: - Infrastructure

    let windowNotifier = WindowNotifier()
    let waterLeakNotifier = WaterLeakNotifier()
    let mdns: MDNSResolver
    private let credentialStore: CredentialStore
    private let skipSideEffects: Bool
    private var cancellables: Set<AnyCancellable> = []
    /// Suppresses the `pinnedDeviceId` / `pinnedRoomId` write-through into the
    /// hub model when those `@Published` fields are being synced *from* a hub
    /// (e.g. on hub switch or initial load).
    private var skipHubSync: Bool = false

    // Cached client — reused across all requests as long as hub + IP are stable.
    // Holds either a `DirigeraClient` (real hub) or a `DemoDirigeraClient`
    // (demo hub) depending on the selected hub's kind.
    private var _cachedClient: (any DirigeraClientProtocol)?
    private var _cachedClientIP: String = ""
    private var _cachedClientHubID: UUID?

    // MARK: - Init

    init(
        credentialStore: CredentialStore? = nil,
        mdns: MDNSResolver? = nil
    ) {
        // Defaults can't appear as default-arg expressions because they need
        // to run in the @MainActor context this init runs in; build them here.
        self.credentialStore = credentialStore ?? KeychainCredentialStore()
        self.mdns = mdns ?? MDNSResolver()

        // When both dependencies are supplied the caller owns the environment
        // (tests / previews). Read stored credentials so init-behaviour tests
        // work, but skip every system subscription and didSet side effect
        // (Combine, NSWorkspace, UserDefaults, Keychain writes) — those can
        // crash on a headless CI runner.
        let injected = credentialStore != nil && mdns != nil
        self.skipSideEffects = Self.isPreview || injected

        if !Self.isPreview {
            self.hubs = Self.loadHubs(credentialStore: self.credentialStore)
            Logger.api.notice(
                "init: loaded \(self.hubs.count, privacy: .public) hub(s) from Keychain"
            )
            for hub in self.hubs {
                Logger.api.notice(
                    "init: hub \"\(hub.displayName, privacy: .public)\" kind=\(hub.kind.rawValue, privacy: .public) isReady=\(hub.isReady, privacy: .public) hasToken=\(hub.accessToken != nil, privacy: .public) hasFingerprint=\(hub.hubFingerprint != nil, privacy: .public) lastKnownIP=\(hub.lastKnownIP ?? "nil", privacy: .public)"
                )
            }
            if let raw = UserDefaults.standard.string(forKey: "selectedHubID"),
                let id = UUID(uuidString: raw),
                self.hubs.contains(where: { $0.id == id })
            {
                self.selectedHubID = id
                Logger.api.notice(
                    "init: selectedHubID restored from UserDefaults — \(id.uuidString, privacy: .public)"
                )
            } else {
                self.selectedHubID = self.hubs.first?.id
                Logger.api.notice(
                    "init: selectedHubID not in UserDefaults — fell back to first hub (\(self.hubs.first?.id.uuidString ?? "nil", privacy: .public))"
                )
            }
            Logger.api.notice(
                "init: selectedHub=\(self.selectedHub?.displayName ?? "nil", privacy: .public) isReady=\(self.selectedHub?.isReady == true, privacy: .public)"
            )
            // Mirror selected hub's pinned IDs into the @Published shadow fields.
            self.skipHubSync = true
            self.pinnedDeviceId = self.selectedHub?.pinnedDeviceId
            self.pinnedRoomId = self.selectedHub?.pinnedRoomId
            self.skipHubSync = false
        }
        guard !Self.isPreview, !injected else { return }
        // Auto-fetch whenever a hub matching the current selection appears
        // on the LAN, and we have credentials for it.
        self.mdns.$discoveredHubs
            .map { [weak self] hubs -> String? in
                // `@Published` fires in willSet, so reading
                // `self.mdns.discoveredHubs` here would see the stale
                // pre-assignment array. Use the value the publisher just
                // emitted directly via the static lookup.
                guard let self, let hub = self.selectedHub else {
                    Logger.api.notice(
                        "mdns-sink/map: discoveredHubs=\(hubs.count, privacy: .public) — no IP (self=\(self != nil, privacy: .public), selectedHub=nil)"
                    )
                    return nil
                }
                let ip = MDNSResolver.ip(forHub: hub, in: hubs)
                Logger.api.notice(
                    "mdns-sink/map: discoveredHubs=\(hubs.count, privacy: .public) — resolved ip=\(ip ?? "nil", privacy: .public) for hub \"\(hub.displayName, privacy: .public)\""
                )
                return ip
            }
            .compactMap { $0 }
            .handleEvents(receiveOutput: { ip in
                Logger.api.notice(
                    "mdns-sink/compactMap: ip=\(ip, privacy: .public) reached removeDuplicates"
                )
            })
            .removeDuplicates()
            .sink { [weak self] ip in
                Logger.api.notice(
                    "mdns-sink/sink: removeDuplicates passed ip=\(ip, privacy: .public) — scheduling fetch"
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.selectedHub?.isReady == true else {
                        Logger.api.error(
                            "mdns-sink/sink: ABORT — selectedHub not ready (selectedHub=\(self.selectedHub?.displayName ?? "nil", privacy: .public), hasToken=\(self.selectedHub?.accessToken != nil, privacy: .public))"
                        )
                        return
                    }
                    Logger.api.notice(
                        "mdns-sink/sink: proceeding to fetchDevices ip=\(ip, privacy: .public)"
                    )
                    await self.fetchDevices(ip: ip, context: "mdns-sink")
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

    // See `MDNSResolver` for why an explicit `nonisolated deinit` is needed.
    nonisolated deinit {}

    private func handleWake() {
        Logger.api.info(
            "System woke from sleep — refreshing devices and reconnecting WebSocket"
        )
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
        if let hub = selectedHub, hub.isReady,
            let ip = mdns.ip(forHub: hub)
        {
            Task { await self.fetchDevices(ip: ip, context: "wake") }
        }
    }

    // MARK: - Client factory

    /// Returns a cached client for the given IP and the currently selected
    /// hub. The cache is keyed on `(hubID, ip)` so switching hubs (or the IP
    /// changing under the same hub) always produces a fresh client — TLS
    /// pinning is per-hub, so reusing a session across hubs would be unsafe.
    /// For demo hubs returns a `DemoDirigeraClient` whose synthetic state and
    /// timer-driven events are wiped when we switch away. Returns `nil` if no
    /// hub with usable credentials is currently selected.
    func makeClient(ip: String) -> (any DirigeraClientProtocol)? {
        guard let hub = selectedHub else { return nil }
        if let cached = _cachedClient,
            _cachedClientIP == ip,
            _cachedClientHubID == hub.id
        {
            return cached
        }
        invalidateCachedClient()
        let client: (any DirigeraClientProtocol)?
        switch hub.kind {
        case .demo:
            client = DemoDirigeraClient()
        case .real:
            client = makeRealClient(for: hub, ip: ip)
        }
        guard let client else { return nil }
        _cachedClient = client
        _cachedClientIP = ip
        _cachedClientHubID = hub.id
        return client
    }

    private func makeRealClient(for hub: Hub, ip: String) -> DirigeraClient? {
        guard let token = hub.accessToken else { return nil }
        let pinnedFingerprint = hub.hubFingerprint.flatMap {
            Data(base64Encoded: $0)
        }
        let hubID = hub.id
        return DirigeraClient(
            ip: ip,
            token: token,
            pinnedLeafFingerprint: pinnedFingerprint,
            onLeafFingerprint: pinnedFingerprint == nil
                ? { [weak self] fp in
                    Task { @MainActor [weak self] in
                        guard let self,
                            let idx = self.hubs.firstIndex(where: { $0.id == hubID }),
                            self.hubs[idx].hubFingerprint == nil
                        else { return }
                        self.hubs[idx].hubFingerprint = fp.base64EncodedString()
                        self.saveHubs()
                        // Evict so the next makeClient builds a session that pins
                        // the now-known fingerprint.
                        self.evictCachedClient()
                    }
                }
                : nil
        )
    }

    private func evictCachedClient() {
        invalidateCachedClient()
        _cachedClient = nil
        _cachedClientIP = ""
        _cachedClientHubID = nil
    }

    /// Tears down a cached client without clearing the cache slots. Only the
    /// real `DirigeraClient` owns a URLSession that needs explicit teardown;
    /// the demo client has no networking and just stops emitting events.
    private func invalidateCachedClient() {
        if let real = _cachedClient as? DirigeraClient {
            real.invalidate()
        }
    }

    // MARK: - Device fetch & events

    func fetchDevices(
        ip: String,
        context: String = "?",
        client injectedClient: (any DirigeraClientProtocol)? = nil
    ) async {
        Logger.api.notice(
            "fetchDevices[\(context, privacy: .public)] ip=\(ip, privacy: .public)"
        )
        guard let client: any DirigeraClientProtocol =
            injectedClient ?? makeClient(ip: ip)
        else {
            Logger.api.error(
                "fetchDevices[\(context, privacy: .public)] ABORT — makeClient returned nil (ip=\(ip, privacy: .public), selectedHub=\(self.selectedHub?.displayName ?? "nil", privacy: .public), kind=\(self.selectedHub?.kind.rawValue ?? "nil", privacy: .public), hasToken=\(self.selectedHub?.accessToken != nil, privacy: .public))"
            )
            return
        }
        isLoadingDevices = true
        devicesError = nil
        do {
            Logger.api.notice(
                "fetchDevices[\(context, privacy: .public)] calling fetchAllDevices…"
            )
            let all = try await client.fetchAllDevices()
            // Sort by id BEFORE merge so each relationId-group iterates in
            // stable id order, and so the final `devices` array is
            // deterministically ordered across re-fetches.
            let sorted = all.sorted { $0.id < $1.id }
            let (merged, idMap) = DirigeraDevice.mergeByRelationId(sorted)
            let withSwitchGroups = DirigeraDevice.collectSwitchGroups(
                merged: merged,
                components: sorted
            )
            let withOutletIds = DirigeraDevice.collectOutletIds(
                merged: withSwitchGroups,
                components: sorted
            )
            gatewayName = withOutletIds.first { $0.isGateway }?.displayName
            devices = withOutletIds.filter { !$0.isGateway }
            deviceIdMap = idMap
            let lc = devices.lights.count
            let sc = devices.openCloseSensors.count
            let ec = devices.envSensors.count
            let pc = devices.smartPlugs.count
            let gw = gatewayName ?? "none"
            Logger.api.info(
                "Fetched \(lc, privacy: .public) light(s), \(sc, privacy: .public) sensor(s), \(ec, privacy: .public) env sensor(s), \(pc, privacy: .public) plug(s), gateway: \(gw, privacy: .public)"
            )
            recordSuccessfulConnection(ip: ip)
            syncPinnedState()
            windowNotifier.update(
                windows: devices.openCloseSensors,
                envSensors: devices.envSensors,
                now: Date()
            )
            waterLeakNotifier.update(sensors: devices)
        } catch {
            devicesError = "Hub unreachable"
            if let urlError = error as? URLError {
                Logger.api.error(
                    "fetchDevices[\(context, privacy: .public)] FAILED — URLError.code=\(urlError.code.rawValue, privacy: .public) (\(String(describing: urlError.code), privacy: .public)) failingURL=\(urlError.failingURL?.absoluteString ?? "nil", privacy: .public) — \(urlError.localizedDescription, privacy: .public)"
                )
            } else {
                Logger.api.error(
                    "fetchDevices[\(context, privacy: .public)] FAILED — \(String(describing: error), privacy: .public)"
                )
            }
        }
        isLoadingDevices = false
    }

    func applyEvent(_ event: DirigeraEvent) {
        guard event.isDeviceStateChanged,
            let data = event.data, let id = data.id
        else { return }
        let primaryId = deviceIdMap[id] ?? id
        guard let i = devices.firstIndex(where: { $0.id == primaryId })
        else { return }
        devices[i].merge(data)
        let updated = devices[i]
        if updated.isLight {
            syncPinnedState()
        } else if updated.isOpenCloseSensor || updated.isEnvironmentSensor {
            windowNotifier.update(
                windows: devices.openCloseSensors,
                envSensors: devices.envSensors,
                now: Date()
            )
        } else if updated.isWaterSensor {
            waterLeakNotifier.update(sensors: devices)
        }
    }

    // MARK: - Light notification

    /// Flashes the pinned light (or all lights that are currently on) red for 1 second,
    /// then restores their previous state. Triggered by a --notify IPC invocation.
    func triggerNotification() async {
        guard let hub = selectedHub,
            let ip = mdns.ip(forHub: hub),
            let client = makeClient(ip: ip),
            let notifier = LightNotifier(
                client: client,
                lights: devices.lights,
                pinnedId: pinnedDeviceId
            )
        else { return }

        await notifier.turnOnDimmed()  // Step 2
        await fetchDevices(ip: ip, context: "notify")  // Step 3
        let presets = notifier.capturePresets(from: devices.lights)  // Step 4
        await notifier.flash()  // Step 5
        try? await Task.sleep(for: .seconds(1))
        await notifier.restore(presets)  // Step 6
        await notifier.turnOffDimmed()  // Step 7
        await fetchDevices(ip: ip, context: "notify")
    }

    // MARK: - Hub lifecycle

    /// Adds a freshly paired hub or updates an existing one matched by fingerprint.
    /// Persists hubs and selects the (added/updated) hub.
    func addOrUpdateHub(
        token: String,
        hubFingerprint: String?,
        gatewayName: String?
    ) {
        let targetID: UUID
        if let fp = hubFingerprint,
            let idx = hubs.firstIndex(where: { $0.hubFingerprint == fp })
        {
            hubs[idx].accessToken = token
            if let name = gatewayName {
                hubs[idx].displayName = name
            }
            targetID = hubs[idx].id
        } else {
            let new = Hub.real(
                displayName: gatewayName ?? Hub.defaultRealDisplayName,
                accessToken: token,
                hubFingerprint: hubFingerprint
            )
            hubs.append(new)
            targetID = new.id
        }
        saveHubs()
        switchHub(to: targetID)
    }

    /// Switches to the hub with `id`, tearing down all device state and the
    /// cached client so the next mDNS resolve / fetch builds a fresh session
    /// against the new hub's credentials. If the new hub is already on the
    /// LAN (or is the demo hub), kicks off an immediate device fetch — the
    /// mDNS pipeline only fires when `discoveredHubs` itself changes, which
    /// won't happen when both old and new hubs are already discovered.
    func switchHub(to id: UUID) {
        guard hubs.contains(where: { $0.id == id }) else { return }
        if id == selectedHubID {
            // Same hub re-selected: sync pinned IDs in case caller expects a
            // refresh, but don't tear down the active session.
            syncPinnedFieldsFromSelectedHub()
            return
        }
        evictCachedClient()
        clearDevices()
        wsRestartToken &+= 1
        selectedHubID = id
        persistSelectedHubID()
        syncPinnedFieldsFromSelectedHub()
        if let hub = selectedHub, hub.isReady,
            let ip = mdns.ip(forHub: hub)
        {
            Task { await self.fetchDevices(ip: ip, context: "switchHub") }
        }
    }

    /// Adds the singleton demo hub if it isn't already in the list, and
    /// switches to it. The demo hub never needs pairing — it's an in-memory
    /// fixture that lets QA exercise every UI surface.
    func addDemoHub() {
        if !hubs.contains(where: { $0.kind == .demo }) {
            hubs.append(Hub.demo())
            saveHubs()
        }
        switchHub(to: Hub.demoID)
    }

    /// `true` if a demo hub already exists in `hubs`. Lets the Settings UI
    /// disable the "Add Demo Hub" button.
    var hasDemoHub: Bool { hubs.contains(where: { $0.kind == .demo }) }

    /// Updates the display name of the hub with `id`. No-op if the hub
    /// doesn't exist or the name is empty.
    func renameHub(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let idx = hubs.firstIndex(where: { $0.id == id })
        else { return }
        hubs[idx].displayName = trimmed
        saveHubs()
    }

    /// Removes the hub with `id`. If it was the selected hub, picks another
    /// (the first remaining) or clears the selection so PairingView is shown.
    func removeHub(_ id: UUID) {
        hubs.removeAll { $0.id == id }
        saveHubs()
        if selectedHubID == id {
            evictCachedClient()
            clearDevices()
            wsRestartToken &+= 1
            selectedHubID = hubs.first?.id
            persistSelectedHubID()
            syncPinnedFieldsFromSelectedHub()
        }
    }

    func syncPinnedState() {
        guard let id = pinnedDeviceId else { return }
        pinnedDeviceIsOn = devices.first { $0.id == id }?.isOn ?? false
    }

    // MARK: - Persistence helpers

    fileprivate static let hubsKey = "dirigeraHubs.v2"

    /// Reads paired hubs from the Keychain. Empty array on first launch or
    /// if the stored JSON is corrupt; PairingView handles either case.
    /// The three failure modes are logged separately so a release-install
    /// trace can tell "Keychain unreadable" apart from "no data" and
    /// "corrupt data".
    private static func loadHubs(credentialStore: CredentialStore) -> [Hub] {
        let raw: String?
        do {
            raw = try credentialStore.get(hubsKey)
        } catch {
            Logger.keychain.error(
                "loadHubs: Keychain read FAILED for \"\(hubsKey, privacy: .public)\" — \(String(describing: error), privacy: .public)"
            )
            return []
        }
        guard let raw, let data = raw.data(using: .utf8) else {
            Logger.keychain.notice(
                "loadHubs: no stored hubs for \"\(hubsKey, privacy: .public)\" (first launch or cleared)"
            )
            return []
        }
        do {
            return try JSONDecoder().decode([Hub].self, from: data)
        } catch {
            Logger.keychain.error(
                "loadHubs: stored hubs JSON is corrupt — \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func saveHubs() {
        guard !skipSideEffects else { return }
        guard let data = try? JSONEncoder().encode(hubs),
            let str = String(data: data, encoding: .utf8)
        else { return }
        if hubs.isEmpty {
            try? credentialStore.delete(Self.hubsKey)
        } else {
            try? credentialStore.set(str, for: Self.hubsKey)
        }
    }

    private func persistSelectedHubID() {
        guard !skipSideEffects else { return }
        if let id = selectedHubID {
            UserDefaults.standard.set(id.uuidString, forKey: "selectedHubID")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedHubID")
        }
    }

    private func mutateSelectedHub(_ block: (inout Hub) -> Void) {
        guard let id = selectedHubID,
            let idx = hubs.firstIndex(where: { $0.id == id })
        else { return }
        block(&hubs[idx])
        saveHubs()
    }

    /// Updates the selected hub's `lastKnownIP` / `lastConnectedAt` after a
    /// successful device fetch, so subsequent launches can prefer that IP
    /// over a fresh mDNS pick when matching paired hubs to LAN endpoints.
    /// Also upgrades a freshly paired hub's `displayName` to the live
    /// `gatewayName` on its first fetch — but only if the user hasn't
    /// already renamed it (heuristic: still equal to the default sentinel).
    private func recordSuccessfulConnection(ip: String) {
        guard ip != "demo" else { return }
        let gateway = gatewayName
        mutateSelectedHub {
            $0.lastKnownIP = ip
            $0.lastConnectedAt = Date()
            if $0.displayName == Hub.defaultRealDisplayName,
                let gateway, !gateway.isEmpty
            {
                $0.displayName = gateway
            }
        }
    }

    private func syncPinnedFieldsFromSelectedHub() {
        skipHubSync = true
        pinnedDeviceId = selectedHub?.pinnedDeviceId
        pinnedRoomId = selectedHub?.pinnedRoomId
        pinnedDeviceIsOn = false
        skipHubSync = false
    }

    private func clearDevices() {
        devices = []
        deviceIdMap = [:]
        gatewayName = nil
        devicesError = nil
    }

    // MARK: - Preview

    // Xcode sets this env var when running previews; used to skip Keychain/UserDefaults I/O.
    static let isPreview =
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    static func preview() -> AppState {
        // Use in-memory credentials and a network-disabled mDNS resolver so
        // SwiftUI previews and unit tests never touch the real Keychain or
        // start a real Bonjour browser.
        let state = AppState(
            credentialStore: InMemoryCredentialStore(),
            mdns: MDNSResolver(networkingEnabled: false)
        )
        let previewHub = Hub.real(
            displayName: "My Smart Home",
            accessToken: "preview-token"
        )
        state.hubs = [previewHub]
        state.selectedHubID = previewHub.id
        state.gatewayName = "My Smart Home"
        let raw: [DirigeraDevice] = [
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
            DirigeraDevice(
                id: "o1",
                type: "blinds",
                room: Room(id: "r2", name: "Bedroom"),
                attributes: .init(
                    customName: "Bedroom Blinds",
                    batteryPercentage: 72
                )
            ),
            DirigeraDevice(
                id: "o2",
                type: "speaker",
                attributes: .init(customName: "Kitchen Speaker")
            ),
            DirigeraDevice(
                id: "s1",
                type: "sensor",
                deviceType: "openCloseSensor",
                room: Room(id: "r1", name: "Living Room"),
                customIcon: "placement_window",
                attributes: .init(
                    customName: "Living Room Window",
                    isOpen: true,
                    batteryPercentage: 20
                )
            ),
            DirigeraDevice(
                id: "s2",
                type: "sensor",
                deviceType: "openCloseSensor",
                room: Room(id: "r2", name: "Kitchen"),
                customIcon: "placement_window",
                attributes: .init(
                    customName: "Kitchen Window",
                    isOpen: false,
                    batteryPercentage: 85
                )
            ),
            DirigeraDevice(
                id: "sw1",
                type: "controller",
                deviceType: "genericSwitch",
                room: Room(id: "r1", name: "Living Room"),
                attributes: .init(
                    customName: "Living Room Remote",
                    batteryPercentage: 88,
                    switchGroups: [1, 2, 3, 4]
                )
            ),
            DirigeraDevice(
                id: "p1-outlet",
                type: "outlet",
                deviceType: "outlet",
                relationId: "plug-rel-1",
                room: Room(id: "r1", name: "Living Room"),
                attributes: .init(
                    customName: "Coffee Maker",
                    isOn: true
                )
            ),
            DirigeraDevice(
                id: "p1-meter",
                type: "outlet",
                relationId: "plug-rel-1",
                room: Room(id: "r1", name: "Living Room"),
                attributes: .init(
                    customName: "Coffee Maker",
                    currentActivePower: 87.3,
                    currentAmps: 0.395,
                    energyConsumedAtLastReset: 8400,
                    timeOfLastEnergyReset: "2025-01-15T10:30:00.000Z",
                    totalEnergyConsumed: 12450
                )
            ),
            // Motion sensor pair: lightSensor + occupancySensor share a
            // relationId. The merge folds illuminance + isDetected into a
            // single device that renders as a MotionSensorRow.
            DirigeraDevice(
                id: "mot1_1",
                type: "unknown",
                deviceType: "lightSensor",
                relationId: "mot1",
                attributes: .init(
                    customName: "Office Motion",
                    batteryPercentage: 100,
                    illuminance: 10792,
                    maxIlluminance: 40001,
                    minIlluminance: 1
                )
            ),
            DirigeraDevice(
                id: "mot1_2",
                type: "sensor",
                deviceType: "occupancySensor",
                relationId: "mot1",
                room: Room(id: "r2", name: "Kitchen"),
                attributes: .init(
                    customName: "Office Motion",
                    batteryPercentage: 100,
                    isDetected: true
                )
            ),
            DirigeraDevice(
                id: "water1",
                type: "sensor",
                deviceType: "waterSensor",
                room: Room(id: "r2", name: "Kitchen"),
                attributes: .init(
                    customName: "Under Sink",
                    batteryPercentage: 92,
                    waterLeakDetected: false
                )
            ),
        ]
        // Run the same merge pipeline as `fetchDevices` so the preview reflects
        // the production data shape (merged plug pair with `outletId` set).
        let sorted = raw.sorted { $0.id < $1.id }
        let (merged, idMap) = DirigeraDevice.mergeByRelationId(sorted)
        let withSwitchGroups = DirigeraDevice.collectSwitchGroups(
            merged: merged,
            components: sorted
        )
        state.devices = DirigeraDevice.collectOutletIds(
            merged: withSwitchGroups,
            components: sorted
        )
        state.deviceIdMap = idMap
        return state
    }
}
