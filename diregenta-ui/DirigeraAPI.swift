@preconcurrency import Foundation

struct Room: Decodable {
    let id: String
    let name: String
}

struct DirigeraDevice: Identifiable, Decodable {
    let id: String
    let type: String
    let deviceType: String?
    let relationId: String?
    let isReachable: Bool?
    let lastSeen: String?
    let room: Room?
    let attributes: Attributes

    struct Attributes: Decodable {
        var customName: String?
        var model: String?
        var isOn: Bool?
        var isOpen: Bool?
        var lightLevel: Int?
        var batteryPercentage: Int?
        var currentTemperature: Double?
        var currentRH: Double?
        var currentCO2: Double?
        var currentPM25: Double?

        func merging(_ other: Attributes?) -> Attributes {
            guard let other else { return self }
            return Attributes(
                customName:          other.customName          ?? customName,
                model:               other.model               ?? model,
                isOn:                other.isOn                ?? isOn,
                isOpen:              other.isOpen              ?? isOpen,
                lightLevel:          other.lightLevel          ?? lightLevel,
                batteryPercentage:   other.batteryPercentage   ?? batteryPercentage,
                currentTemperature:  other.currentTemperature  ?? currentTemperature,
                currentRH:           other.currentRH           ?? currentRH,
                currentCO2:          other.currentCO2          ?? currentCO2,
                currentPM25:         other.currentPM25         ?? currentPM25
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
        delegate: InsecureTLSDelegate(),
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
                                    print("[WS] \(event.type) id=\(event.data?.id ?? "-")")
                                    continuation.yield(event)
                                }
                            }
                        }
                        receive()
                    case .failure(let error):
                        print("[WS] Disconnected: \(error)")
                        continuation.finish()
                    }
                }
            }

            print("[WS] Connecting to \(url)")
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
        print("[API] → \(req.httpMethod ?? "?") \(req.url?.absoluteString ?? "?")")
        if let body = req.httpBody, let s = String(data: body, encoding: .utf8) {
            print("[API]   body: \(s)")
        }
    }

    private func log(_ response: URLResponse, data: Data) {
        if let http = response as? HTTPURLResponse {
            print("[API] ← \(http.statusCode) \(http.url?.absoluteString ?? "?")")
        }
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            print("[API]   body: \(s)")
        }
    }
}

// Dirigera uses a self-signed certificate on the local network.
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
