import CryptoKit
@preconcurrency import Foundation
import OSLog

nonisolated struct Room: Decodable {
    let id: String
    let name: String
}

nonisolated struct DirigeraDevice: Identifiable, Decodable {
    let id: String
    var type: String
    var deviceType: String? = nil
    var relationId: String? = nil
    var isReachable: Bool? = nil
    var lastSeen: String? = nil
    var room: Room? = nil
    var customIcon: String? = nil
    var attributes: Attributes

    struct Attributes: Decodable {
        var customName: String? = nil
        var model: String? = nil
        var isOn: Bool? = nil
        var isOpen: Bool? = nil
        var lightLevel: Int? = nil
        var batteryPercentage: Int? = nil
        var currentTemperature: Double? = nil
        var currentRH: Double? = nil
        var currentCO2: Double? = nil
        var currentPM25: Double? = nil
        var colorTemperature: Int? = nil
        var colorTemperatureMin: Int? = nil
        var colorTemperatureMax: Int? = nil
        var colorHue: Double? = nil
        var colorSaturation: Double? = nil
        var colorMode: String? = nil // "color" | "temperature"

        /// Overwrites each field with the corresponding non-nil value from `other`.
        /// Add new fields here whenever Attributes gains a new property.
        mutating func merge(_ other: Attributes?) {
            guard let other else { return }
            if let v = other.customName { customName = v }
            if let v = other.model { model = v }
            if let v = other.isOn { isOn = v }
            if let v = other.isOpen { isOpen = v }
            if let v = other.lightLevel { lightLevel = v }
            if let v = other.batteryPercentage { batteryPercentage = v }
            if let v = other.currentTemperature { currentTemperature = v }
            if let v = other.currentRH { currentRH = v }
            if let v = other.currentCO2 { currentCO2 = v }
            if let v = other.currentPM25 { currentPM25 = v }
            if let v = other.colorTemperature { colorTemperature = v }
            if let v = other.colorTemperatureMin { colorTemperatureMin = v }
            if let v = other.colorTemperatureMax { colorTemperatureMax = v }
            if let v = other.colorHue { colorHue = v }
            if let v = other.colorSaturation { colorSaturation = v }
            if let v = other.colorMode { colorMode = v }
        }
    }

    var displayName: String { attributes.customName ?? id }
    var isOn: Bool { attributes.isOn ?? false }
    var isOpen: Bool { attributes.isOpen ?? false }

    var lightSymbol: String {
        switch customIcon {
        case "products_chandelier_bulb": return "lightbulb.led.wide"
        case "lighting_pendant_light",
            "lighting_cone_pendant":
            return "lamp.ceiling"
        case "lighting_chandelier": return "chandelier"
        case "lighting_ached_lamp": return "lamp.desk"
        case "lighting_nightstand_light",
            "lighting_wall_lamp":
            return "lamp.table"
        case "lighting_floor_lamp": return "lamp.floor"
        case "lighting_spot_chandelier": return "light.recessed.3"
        default: return "lightbulb.led"
        }
    }

    func lightIcon(isOn: Bool) -> String {
        isOn ? lightSymbol + ".fill" : lightSymbol
    }

    mutating func merge(_ data: DirigeraEvent.DeviceData) {
        if let v = data.type { type = v }
        if let v = data.deviceType { deviceType = v }
        if let v = data.isReachable { isReachable = v }
        if let v = data.lastSeen { lastSeen = v }
        if let v = data.room { room = v }
        if let v = data.customIcon { customIcon = v }
        attributes.merge(data.attributes)
    }
}

nonisolated extension DirigeraDevice {
    var isLight: Bool { type == "light" }
    var isGateway: Bool { type == "gateway" }
    var isOpenCloseSensor: Bool { deviceType == "openCloseSensor" }
    var isEnvironmentSensor: Bool { deviceType == "environmentSensor" }

    /// True if the light supports a white-spectrum (colour-temperature) slider.
    var isColorTemperatureLight: Bool { attributes.colorTemperatureMin != nil }
    /// True if the light supports full RGB colour (hue + saturation).
    var isColorLight: Bool { attributes.colorHue != nil }
    /// True if either colour control is available for this light.
    var supportsColorControls: Bool { isColorTemperatureLight || isColorLight }

    /// The light's current appearance preset (level + colour/temperature),
    /// determined by `colorMode`. Returns nil for lights with neither level
    /// nor colour support.
    var colorPreset: LightColorPreset? {
        guard isLight else { return nil }
        let level = attributes.lightLevel
        guard supportsColorControls || level != nil else { return nil }

        if supportsColorControls {
            switch attributes.colorMode {
            case "color":
                if let hue = attributes.colorHue, let sat = attributes.colorSaturation {
                    return LightColorPreset(lightLevel: level, hue: hue, saturation: sat)
                }
            case "temperature":
                if let ct = attributes.colorTemperature {
                    return LightColorPreset(lightLevel: level, colorTemperature: ct)
                }
            default:
                // colorMode not reported — use whichever values are present.
                if let hue = attributes.colorHue, let sat = attributes.colorSaturation {
                    return LightColorPreset(lightLevel: level, hue: hue, saturation: sat)
                } else if let ct = attributes.colorTemperature {
                    return LightColorPreset(lightLevel: level, colorTemperature: ct)
                }
            }
        }
        // Fall back to level-only preset.
        if let level { return LightColorPreset(lightLevel: level) }
        return nil
    }

    /// UserDefaults key for persisting this light's saved colour/brightness default.
    var colorDefaultsKey: String { "lightColorDefault.\(id)" }

    /// Merges env-sensor components that share a `relationId` into a single device.
    /// Returns the merged list and a map from each component id to the primary device id,
    /// used to route WebSocket events back to the right merged entry.
    static func mergeEnvSensors(_ sensors: [DirigeraDevice]) -> (
        [DirigeraDevice], [String: String]
    ) {
        var byRelation: [String: [DirigeraDevice]] = [:]
        var result: [DirigeraDevice] = []
        var idMap: [String: String] = [:]

        for sensor in sensors {
            if let rel = sensor.relationId {
                byRelation[rel, default: []].append(sensor)
            } else {
                result.append(sensor)
            }
        }

        for (_, group) in byRelation {
            // Sort so devices whose customName == model (generic default) come first;
            // the fold's last value wins, so the real user-set name ends up on top.
            let sorted = group.sorted { a, _ in
                a.attributes.customName == a.attributes.model
            }
            guard let first = sorted.first else { continue }
            var mergedAttrs = first.attributes
            for device in sorted.dropFirst() { mergedAttrs.merge(device.attributes) }
            let room = sorted.first(where: { $0.room != nil })?.room
            result.append(
                DirigeraDevice(
                    id: first.id,
                    type: first.type,
                    deviceType: first.deviceType,
                    relationId: first.relationId,
                    isReachable: first.isReachable,
                    lastSeen: first.lastSeen,
                    room: room,
                    customIcon: first.customIcon,
                    attributes: mergedAttrs
                )
            )
            for sensor in sorted { idMap[sensor.id] = first.id }
        }

        return (result, idMap)
    }

    struct Reading {
        let text: String
        let outOfRange: Bool
    }

    var envReadings: [Reading] {
        var parts: [Reading] = []
        if let t = attributes.currentTemperature {
            parts.append(
                Reading(
                    text: String(format: "%.1f°C", t),
                    outOfRange: !(18.0...26.0 ~= t)
                )
            )
        }
        if let rh = attributes.currentRH {
            parts.append(
                Reading(
                    text: String(format: "%.0f%% RH", rh),
                    outOfRange: !(30.0...60.0 ~= rh)
                )
            )
        }
        if let co2 = attributes.currentCO2 {
            parts.append(
                Reading(
                    text: String(format: "%.0f ppm CO₂", co2),
                    outOfRange: co2 > 1000
                )
            )
        }
        if let pm = attributes.currentPM25 {
            parts.append(
                Reading(
                    text: String(format: "%.0f µg/m³ PM2.5", pm),
                    outOfRange: pm > 12
                )
            )
        }
        return parts
    }

    var isComfortable: Bool { envReadings.allSatisfy { !$0.outOfRange } }

    static func averagedEnvReadings(from sensors: [DirigeraDevice]) -> [Reading]
    {
        let avg: ([Double]) -> Double? = {
            $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count)
        }
        let virtual = DirigeraDevice(
            id: "",
            type: "sensor",
            deviceType: "environmentSensor",
            attributes: .init(
                currentTemperature: avg(
                    sensors.compactMap { $0.attributes.currentTemperature }
                ),
                currentRH: avg(sensors.compactMap { $0.attributes.currentRH }),
                currentCO2: avg(
                    sensors.compactMap { $0.attributes.currentCO2 }
                ),
                currentPM25: avg(
                    sensors.compactMap { $0.attributes.currentPM25 }
                )
            )
        )
        return virtual.envReadings
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func openSeconds(now: Date) -> Int? {
        guard let raw = lastSeen else { return nil }
        let date =
            Self.isoFractional.date(from: raw) ?? Self.isoPlain.date(from: raw)
        guard let date else { return nil }
        let s = Int(now.timeIntervalSince(date))
        return s > 0 ? s : nil
    }

    func openDuration(now: Date) -> String? {
        guard let s = openSeconds(now: now) else { return nil }
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }
}

nonisolated struct DirigeraEvent: Decodable {
    let type: String
    let data: DeviceData?
    var isDeviceStateChanged: Bool { type == "deviceStateChanged" }

    struct DeviceData: Decodable {
        let id: String?
        let type: String?
        let deviceType: String?
        let isReachable: Bool?
        let lastSeen: String?
        let room: Room?
        let customIcon: String?
        let attributes: DirigeraDevice.Attributes?
    }
}

/// A light's colour/temperature state, used for saving presets and for
/// snapshot/restore in the notification flash.
nonisolated struct LightColorPreset: Codable {
    /// Brightness level 1–100.
    var lightLevel: Int? = nil
    /// Colour-temperature mode value in Kelvin (mutually exclusive with hue/saturation).
    var colorTemperature: Int? = nil
    /// Hue in degrees 0–360 (colour mode).
    var hue: Double? = nil
    /// Saturation 0–1 (colour mode).
    var saturation: Double? = nil
}

// Used by patchAttributes — must live outside the generic function due to Swift restrictions.
private struct PatchBody<A: Encodable>: Encodable {
    let attributes: A
}

/// The subset of DirigeraClient used by LightNotifier and the flash sequence,
/// extracted as a protocol so tests can substitute a recording mock.
protocol DirigeraClientProtocol: Sendable {
    func setLight(id: String, isOn: Bool) async throws
    func setLightLevel(id: String, lightLevel: Int) async throws
    func setColor(id: String, hue: Double, saturation: Double) async throws
    func applyColorPreset(_ preset: LightColorPreset, to id: String) async throws
}

final class DirigeraClient {
    private let ip: String
    private let token: String
    private let session: URLSession

    init(
        ip: String,
        token: String,
        pinnedLeafFingerprint: Data? = nil,
        onLeafFingerprint: ((Data) -> Void)? = nil
    ) {
        self.ip = ip
        self.token = token
        self.session = URLSession(
            configuration: .default,
            delegate: PinnedCertificateTLSDelegate(
                requiredLeafFingerprint: pinnedLeafFingerprint,
                onLeafFingerprint: onLeafFingerprint
            ),
            delegateQueue: nil
        )
    }

    init(ip: String, token: String, session: URLSession) {
        self.ip = ip
        self.token = token
        self.session = session
    }

    /// Drains in-flight tasks and releases the URLSession + its delegate.
    /// Call this before discarding the client.
    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    func eventStream() -> AsyncStream<DirigeraEvent> {
        // Frame decoding is delegated to decodeDirigeraWebSocketFrame so
        // the decode logic can be unit-tested independently of URLSession.
        AsyncStream { continuation in
            guard let url = URL(string: "wss://\(ip):8443/v1") else {
                continuation.finish()
                return
            }
            var request = URLRequest(url: url)
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
            let task = session.webSocketTask(with: request)

            func receive() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        if let event = decodeDirigeraWebSocketFrame(message) {
                            Task { @MainActor in
                                Logger.webSocket.debug(
                                    "\(event.type, privacy: .public) id=\(event.data?.id ?? "-", privacy: .public)"
                                )
                                continuation.yield(event)
                            }
                        }
                        receive()
                    case .failure(let error):
                        Logger.webSocket.error(
                            "Disconnected: \(error.localizedDescription, privacy: .public)"
                        )
                        continuation.finish()
                    }
                }
            }

            Logger.webSocket.info(
                "Connecting to \(url.absoluteString, privacy: .public)"
            )
            task.resume()
            receive()
            continuation.onTermination = { _ in
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    func fetchAllDevices() async throws -> [DirigeraDevice] {
        let data = try await get("/v1/devices")
        return try JSONDecoder().decode([DirigeraDevice].self, from: data)
    }

    func setLight(id: String, isOn: Bool) async throws {
        struct Attrs: Encodable { let isOn: Bool }
        try await patchAttributes(Attrs(isOn: isOn), deviceId: id)
    }

    func setLightLevel(id: String, lightLevel: Int) async throws {
        struct Attrs: Encodable { let lightLevel: Int }
        try await patchAttributes(Attrs(lightLevel: lightLevel), deviceId: id)
    }

    func setColorTemperature(id: String, colorTemperature: Int) async throws {
        struct Attrs: Encodable { let colorTemperature: Int }
        try await patchAttributes(
            Attrs(colorTemperature: colorTemperature),
            deviceId: id
        )
    }

    func applyColorPreset(_ preset: LightColorPreset, to id: String) async throws {
        if let hue = preset.hue, let sat = preset.saturation {
            try await setColor(id: id, hue: hue, saturation: sat)
        } else if let ct = preset.colorTemperature {
            try await setColorTemperature(id: id, colorTemperature: ct)
        }
        if let level = preset.lightLevel {
            try await setLightLevel(id: id, lightLevel: level)
        }
    }

    func setColor(id: String, hue: Double, saturation: Double) async throws {
        struct Attrs: Encodable {
            let colorHue: Double
            let colorSaturation: Double
        }
        try await patchAttributes(
            Attrs(colorHue: hue, colorSaturation: saturation),
            deviceId: id
        )
    }

    // Dirigera expects an array of patch operations, not a bare object.
    private func patchAttributes<A: Encodable>(_ attrs: A, deviceId id: String)
        async throws
    {
        let body = try JSONEncoder().encode([PatchBody(attributes: attrs)])
        try await patch("/v1/devices/\(id)", body: body)
    }

    private func get(_ path: String) async throws -> Data {
        var req = try makeRequest(path)
        req.httpMethod = "GET"
        log(req)
        let (data, response) = try await session.data(for: req)
        log(response, data: data)
        try validate(response)
        return data
    }

    private func patch(_ path: String, body: Data) async throws {
        var req = try makeRequest(path)
        req.httpMethod = "PATCH"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        log(req)
        let (data, response) = try await session.data(for: req)
        log(response, data: data)
        try validate(response)
    }

    private func makeRequest(_ path: String) throws -> URLRequest {
        guard let url = URL(string: "https://\(ip):8443\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
    }

    private func log(_ req: URLRequest) {
        let method = req.httpMethod ?? "?"
        let url = req.url?.absoluteString ?? "?"
        Logger.api.debug(
            "→ \(method, privacy: .public) \(url, privacy: .public)"
        )
        if let body = req.httpBody, let s = String(data: body, encoding: .utf8)
        {
            Logger.api.debug("  body: \(s, privacy: .public)")
        }
    }

    private func log(_ response: URLResponse, data: Data) {
        if let http = response as? HTTPURLResponse {
            let status = http.statusCode
            let url = http.url?.absoluteString ?? "?"
            Logger.api.debug(
                "← \(status, privacy: .public) \(url, privacy: .public)"
            )
        }
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            Logger.api.debug("  body: \(s, privacy: .public)")
        }
    }
}

extension DirigeraClient: DirigeraClientProtocol {}

/// Decodes a single WebSocket message frame into a `DirigeraEvent`.
/// Returns `nil` for binary frames, frames that aren't valid UTF-8, or frames
/// whose JSON doesn't match the `DirigeraEvent` schema — none of these should
/// terminate the stream.
/// Extracted as a free function so the decode logic can be unit-tested
/// independently of URLSessionWebSocketTask.
nonisolated func decodeDirigeraWebSocketFrame(
    _ message: URLSessionWebSocketTask.Message
) -> DirigeraEvent? {
    switch message {
    case .string(let text):
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(DirigeraEvent.self, from: data)
        } catch {
            Logger.webSocket.warning(
                "Decode error: \(error.localizedDescription, privacy: .public) — frame: \(text.prefix(200), privacy: .public)"
            )
            return nil
        }
    case .data(let data):
        Logger.webSocket.warning(
            "Unexpected binary frame (\(data.count) bytes), skipping"
        )
        return nil
    @unknown default:
        return nil
    }
}

// Validates the Dirigera hub's TLS certificate against the pinned IKEA Home smart Root CA.
// Optionally enforces leaf-level pinning: if `requiredLeafFingerprint` is set, the connection
// is rejected unless the hub's leaf cert SHA-256 matches exactly — preventing token leakage
// to any hub other than the one the app was originally paired with.
private final class PinnedCertificateTLSDelegate: NSObject, URLSessionDelegate {
    let requiredLeafFingerprint: Data?
    let onLeafFingerprint: ((Data) -> Void)?

    init(
        requiredLeafFingerprint: Data? = nil,
        onLeafFingerprint: ((Data) -> Void)? = nil
    ) {
        self.requiredLeafFingerprint = requiredLeafFingerprint
        self.onLeafFingerprint = onLeafFingerprint
    }

    // DER-encoded IKEA Home smart Root CA (valid until 2071-05-14).
    private static let rootCADER = Data(
        base64Encoded: """
            MIICGDCCAZ+gAwIBAgIUdfH0KDnENv/dEcxH8iVqGGGDqrowCgYIKoZIzj0EAwMw
            SzELMAkGA1UEBhMCU0UxGjAYBgNVBAoMEUlLRUEgb2YgU3dlZGVuIEFCMSAwHgYD
            VQQDDBdJS0VBIEhvbWUgc21hcnQgUm9vdCBDQTAgFw0yMTA1MjYxOTAxMDlaGA8y
            MDcxMDUxNDE5MDEwOFowSzELMAkGA1UEBhMCU0UxGjAYBgNVBAoMEUlLRUEgb2Yg
            U3dlZGVuIEFCMSAwHgYDVQQDDBdJS0VBIEhvbWUgc21hcnQgUm9vdCBDQTB2MBAG
            ByqGSM49AgEGBSuBBAAiA2IABIDRUvKGFMUu2zIhTdgfrfNcPULwMlc0TGSrDLBA
            oTr0SMMV4044CRZQbl81N4qiuHGhFzCnXapZogkiVuFu7ZqSslsFuELFjc6ZxBjk
            Kmud+pQM6QQdsKTE/cS06dA+P6NCMEAwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4E
            FgQUcdlEnfX0MyZA4zAdY6CLOye9wfwwDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49
            BAMDA2cAMGQCMG6mFIeB2GCFch3r0Gre4xRH+f5pn/bwLr9yGKywpeWvnUPsQ1KW
            ckMLyxbeNPXdQQIwQc2YZDq/Mz0mOkoheTUWiZxK2a5bk0Uz1XuGshXmQvEg5TGy
            2kVHW/Mz9/xwpy4u
            """,
        options: .ignoreUnknownCharacters
    )!

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping (URLSession.AuthChallengeDisposition, URLCredential?) ->
            Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust
        else {
            Logger.api.warning(
                "[TLS] Unexpected auth method: \(challenge.protectionSpace.authenticationMethod, privacy: .public)"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            Logger.api.warning("[TLS] No serverTrust in challenge")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard
            let pinnedCert = SecCertificateCreateWithData(
                nil,
                PinnedCertificateTLSDelegate.rootCADER as CFData
            )
        else {
            Logger.api.error("[TLS] Failed to decode pinned root CA DER data")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Use basic X.509 chain validation instead of the default SSL policy.
        // The hub's leaf cert fails Apple's SSL policy on three counts: hostname mismatch
        // (cert uses the hub's name, not its IP), temporal validity (IKEA issues certs
        // with a longer lifetime than Apple's 398-day limit), and EKU mismatch. None of
        // these affect the security property we care about — that the cert chains to the
        // pinned IKEA root CA — so we validate only the chain.
        SecTrustSetPolicies(trust, [SecPolicyCreateBasicX509()] as CFArray)

        SecTrustSetAnchorCertificates(trust, [pinnedCert] as CFArray)
        // Only trust our pinned anchor — ignore the system keychain.
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            Logger.api.warning(
                "[TLS] Trust evaluation failed for \(challenge.protectionSpace.host, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract the leaf certificate's SHA-256 fingerprint for hub-specific pinning.
        let chain =
            SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let leafFingerprint = Data(
            SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        )
        if let required = requiredLeafFingerprint, leafFingerprint != required {
            Logger.api.warning(
                "[TLS] Leaf cert fingerprint mismatch — rejecting \(challenge.protectionSpace.host, privacy: .public)"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        onLeafFingerprint?(leafFingerprint)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Pairing

// Implements the Dirigera PKCE OAuth flow:
//   1. requestPairing()    → get an authorization code from the hub
//   2. (user presses the button on top of the hub)
//   3. exchangeToken(...)  → exchange code + verifier for a bearer token
//
// A single instance must be used for both steps so that:
//   • only one URLSession is allocated and later properly invalidated, and
//   • the leaf certificate fingerprint captured during step 1 can be stored
//     in AppState so every subsequent DirigeraClient connection is pinned.
final class DirigeraAuthClient {
    let ip: String
    private let session: URLSession

    /// Leaf-certificate fingerprint captured during the first TLS handshake.
    /// Available after `requestPairing()` completes successfully.
    var capturedFingerprint: Data? { fingerprintBox.data }

    // FingerprintBox decouples fingerprint storage from self so the
    // session→delegate→closure→box chain has no back-reference to self,
    // avoiding a retain cycle without needing invalidate() to break one.
    private let fingerprintBox = FingerprintBox()

    init(ip: String, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.ip = ip
        let box = fingerprintBox
        let config = sessionConfiguration ?? .default
        let delegate: URLSessionDelegate?
        if sessionConfiguration == nil {
            delegate = PinnedCertificateTLSDelegate(
                requiredLeafFingerprint: nil,
                onLeafFingerprint: { fp in box.data = fp }
            )
        } else {
            delegate = nil
        }
        session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// Drains in-flight tasks and releases the URLSession + its delegate.
    /// Always call this when the pairing flow finishes (success, failure, or cancel).
    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    func requestPairing() async throws -> (code: String, verifier: String) {
        let verifier = Self.makeVerifier()
        let challenge = Self.makeChallenge(for: verifier)

        struct Body: Encodable {
            let audience = "homesmart.local"
            let grantType = "authorization_code"
            let codeChallenge: String
            let codeChallengeMethod = "S256"
            enum CodingKeys: String, CodingKey {
                case audience
                case grantType = "grant_type"
                case codeChallenge = "code_challenge"
                case codeChallengeMethod = "code_challenge_method"
            }
        }
        struct Response: Decodable {
            let authorizationCode: String
            enum CodingKeys: String, CodingKey {
                case authorizationCode = "authorization_code"
            }
        }

        let data = try await post(
            "/v1/oauth/authorize",
            body: try JSONEncoder().encode(Body(codeChallenge: challenge))
        )
        let code = try JSONDecoder().decode(Response.self, from: data)
            .authorizationCode
        return (code: code, verifier: verifier)
    }

    func exchangeToken(code: String, verifier: String) async throws -> String {
        struct Body: Encodable {
            let code: String
            let name = "dirigenta-ui"
            let grantType = "authorization_code"
            let codeVerifier: String
            enum CodingKeys: String, CodingKey {
                case code, name
                case grantType = "grant_type"
                case codeVerifier = "code_verifier"
            }
        }
        struct Response: Decodable {
            let accessToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
            }
        }

        let data = try await post(
            "/v1/oauth/token",
            body: try JSONEncoder().encode(
                Body(code: code, codeVerifier: verifier)
            )
        )
        return try JSONDecoder().decode(Response.self, from: data).accessToken
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        guard let url = URL(string: "https://\(ip):8443\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncoded()
    }

    static func makeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private final class FingerprintBox {
    var data: Data?
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
