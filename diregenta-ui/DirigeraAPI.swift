@preconcurrency import Foundation
import OSLog

struct Room: Decodable {
    let id: String
    let name: String
}

struct DirigeraDevice: Identifiable, Decodable {
    let id: String
    let type: String
    var deviceType: String?    = nil
    var relationId: String?    = nil
    var isReachable: Bool?     = nil
    var lastSeen: String?      = nil
    var room: Room?            = nil
    let attributes: Attributes

    struct Attributes: Decodable {
        var customName: String?           = nil
        var model: String?                = nil
        var isOn: Bool?                   = nil
        var isOpen: Bool?                 = nil
        var lightLevel: Int?              = nil
        var batteryPercentage: Int?       = nil
        var currentTemperature: Double?   = nil
        var currentRH: Double?            = nil
        var currentCO2: Double?           = nil
        var currentPM25: Double?          = nil
        var colorTemperature: Int?        = nil
        var colorTemperatureMin: Int?     = nil
        var colorTemperatureMax: Int?     = nil
        var colorHue: Double?             = nil
        var colorSaturation: Double?      = nil

        func merging(_ other: Attributes?) -> Attributes {
            guard let other else { return self }
            return Attributes(
                customName:           other.customName           ?? customName,
                model:                other.model                ?? model,
                isOn:                 other.isOn                 ?? isOn,
                isOpen:               other.isOpen               ?? isOpen,
                lightLevel:           other.lightLevel           ?? lightLevel,
                batteryPercentage:    other.batteryPercentage    ?? batteryPercentage,
                currentTemperature:   other.currentTemperature   ?? currentTemperature,
                currentRH:            other.currentRH            ?? currentRH,
                currentCO2:           other.currentCO2           ?? currentCO2,
                currentPM25:          other.currentPM25          ?? currentPM25,
                colorTemperature:     other.colorTemperature     ?? colorTemperature,
                colorTemperatureMin:  other.colorTemperatureMin  ?? colorTemperatureMin,
                colorTemperatureMax:  other.colorTemperatureMax  ?? colorTemperatureMax,
                colorHue:             other.colorHue             ?? colorHue,
                colorSaturation:      other.colorSaturation      ?? colorSaturation
            )
        }
    }

    var displayName: String { attributes.customName ?? id }
    var isOn: Bool { attributes.isOn ?? false }
    var isOpen: Bool { attributes.isOpen ?? false }

    func modifyingAttributes(_ transform: (inout Attributes) -> Void) -> DirigeraDevice {
        var updated = attributes
        transform(&updated)
        return DirigeraDevice(id: id, type: type, deviceType: deviceType, relationId: relationId,
                              isReachable: isReachable, lastSeen: lastSeen, room: room, attributes: updated)
    }

    func withIsOn(_ value: Bool) -> DirigeraDevice { modifyingAttributes { $0.isOn = value } }
    func withLightLevel(_ value: Int) -> DirigeraDevice { modifyingAttributes { $0.lightLevel = value } }
    func withColorTemperature(_ value: Int) -> DirigeraDevice { modifyingAttributes { $0.colorTemperature = value } }
    func withColor(hue: Double, saturation: Double) -> DirigeraDevice {
        modifyingAttributes { $0.colorHue = hue; $0.colorSaturation = saturation }
    }

    func merging(_ data: DirigeraEvent.DeviceData) -> DirigeraDevice {
        DirigeraDevice(
            id: id,
            type: data.type ?? type,
            deviceType: data.deviceType ?? deviceType,
            relationId: relationId,
            isReachable: data.isReachable ?? isReachable,
            lastSeen: data.lastSeen ?? lastSeen,
            room: data.room ?? room,
            attributes: attributes.merging(data.attributes)
        )
    }
}

extension DirigeraDevice {
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

    /// Merges env-sensor components that share a `relationId` into a single device.
    /// Returns the merged list and a map from each component id to the primary device id,
    /// used to route WebSocket events back to the right merged entry.
    static func mergeEnvSensors(_ sensors: [DirigeraDevice]) -> ([DirigeraDevice], [String: String]) {
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
            let sorted = group.sorted { a, _ in a.attributes.customName == a.attributes.model }
            guard let first = sorted.first else { continue }
            let mergedAttrs = sorted.dropFirst().reduce(first.attributes) { $0.merging($1.attributes) }
            result.append(DirigeraDevice(
                id: first.id, type: first.type, deviceType: first.deviceType,
                relationId: first.relationId, isReachable: first.isReachable,
                lastSeen: first.lastSeen, room: first.room, attributes: mergedAttrs
            ))
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
        if let t   = attributes.currentTemperature { parts.append(Reading(text: String(format: "%.1f°C", t),            outOfRange: !(18.0...26.0 ~= t))) }
        if let rh  = attributes.currentRH         { parts.append(Reading(text: String(format: "%.0f%% RH", rh),        outOfRange: !(30.0...60.0 ~= rh))) }
        if let co2 = attributes.currentCO2        { parts.append(Reading(text: String(format: "%.0f ppm CO₂", co2),    outOfRange: co2 > 1000)) }
        if let pm  = attributes.currentPM25       { parts.append(Reading(text: String(format: "%.0f µg/m³ PM2.5", pm), outOfRange: pm > 12)) }
        return parts
    }

    var isComfortable: Bool { envReadings.allSatisfy { !$0.outOfRange } }
}

struct DirigeraEvent: Decodable {
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
        let attributes: DirigeraDevice.Attributes?
    }
}

// Used by patchAttributes — must live outside the generic function due to Swift restrictions.
private struct PatchBody<A: Encodable>: Encodable {
    let attributes: A
}

final class DirigeraClient {
    private let ip: String
    private let token: String
    private lazy var session = URLSession(
        configuration: .default,
        delegate: PinnedCertificateTLSDelegate(),
        delegateQueue: nil
    )

    init(ip: String, token: String) {
        self.ip = ip
        self.token = token
    }

    func eventStream() -> AsyncStream<DirigeraEvent> {
        AsyncStream { continuation in
            guard let url = URL(string: "wss://\(ip):8443/v1") else {
                continuation.finish(); return
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)

            func receive() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        if case .string(let text) = message,
                           let data = text.data(using: .utf8) {
                            Task { @MainActor in
                                if let event = try? JSONDecoder().decode(DirigeraEvent.self, from: data) {
                                    Logger.webSocket.debug("\(event.type, privacy: .public) id=\(event.data?.id ?? "-", privacy: .public)")
                                    continuation.yield(event)
                                }
                            }
                        }
                        receive()
                    case .failure(let error):
                        Logger.webSocket.error("Disconnected: \(error.localizedDescription, privacy: .public)")
                        continuation.finish()
                    }
                }
            }

            Logger.webSocket.info("Connecting to \(url.absoluteString, privacy: .public)")
            task.resume()
            receive()
            continuation.onTermination = { _ in task.cancel(with: .normalClosure, reason: nil) }
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
        try await patchAttributes(Attrs(colorTemperature: colorTemperature), deviceId: id)
    }

    func setColor(id: String, hue: Double, saturation: Double) async throws {
        struct Attrs: Encodable { let colorHue: Double; let colorSaturation: Double }
        try await patchAttributes(Attrs(colorHue: hue, colorSaturation: saturation), deviceId: id)
    }

    // Dirigera expects an array of patch operations, not a bare object.
    private func patchAttributes<A: Encodable>(_ attrs: A, deviceId id: String) async throws {
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func log(_ req: URLRequest) {
        let method = req.httpMethod ?? "?"
        let url    = req.url?.absoluteString ?? "?"
        Logger.api.debug("→ \(method, privacy: .public) \(url, privacy: .public)")
        if let body = req.httpBody, let s = String(data: body, encoding: .utf8) {
            Logger.api.debug("  body: \(s, privacy: .public)")
        }
    }

    private func log(_ response: URLResponse, data: Data) {
        if let http = response as? HTTPURLResponse {
            let status = http.statusCode
            let url    = http.url?.absoluteString ?? "?"
            Logger.api.debug("← \(status, privacy: .public) \(url, privacy: .public)")
        }
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            Logger.api.debug("  body: \(s, privacy: .public)")
        }
    }
}

// Validates the Dirigera hub's TLS certificate against the pinned IKEA Home smart Root CA.
private final class PinnedCertificateTLSDelegate: NSObject, URLSessionDelegate {
    // DER-encoded IKEA Home smart Root CA (valid until 2071-05-14).
    private static let rootCADER = Data(base64Encoded: """
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
        """, options: .ignoreUnknownCharacters)!

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pinnedCert = SecCertificateCreateWithData(nil, PinnedCertificateTLSDelegate.rootCADER as CFData)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        SecTrustSetAnchorCertificates(trust, [pinnedCert] as CFArray)
        // Only trust our pinned anchor — ignore the system keychain.
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
