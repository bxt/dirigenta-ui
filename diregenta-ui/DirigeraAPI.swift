import Foundation

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
        let customName: String?
        let isOn: Bool?
        let isOpen: Bool?
        let batteryPercentage: Int?
        let currentTemperature: Double?
        let currentRH: Double?
        let currentCO2: Double?
        let currentPM25: Double?

        func merging(_ other: Attributes?) -> Attributes {
            guard let other else { return self }
            return Attributes(
                customName:          other.customName          ?? customName,
                isOn:                other.isOn                ?? isOn,
                isOpen:              other.isOpen              ?? isOpen,
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

    func withIsOn(_ value: Bool) -> DirigeraDevice {
        DirigeraDevice(id: id, type: type, deviceType: deviceType, relationId: relationId, isReachable: isReachable, lastSeen: lastSeen, room: room,
                       attributes: Attributes(customName: attributes.customName, isOn: value,
                                              isOpen: attributes.isOpen,
                                              batteryPercentage: attributes.batteryPercentage,
                                              currentTemperature: attributes.currentTemperature,
                                              currentRH: attributes.currentRH,
                                              currentCO2: attributes.currentCO2,
                                              currentPM25: attributes.currentPM25))
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

struct DirigeraEvent: Decodable {
    let type: String
    let data: DeviceData?

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
                           let data = text.data(using: .utf8),
                           let event = try? JSONDecoder().decode(DirigeraEvent.self, from: data) {
                            print("[WS] \(event.type) id=\(event.data?.id ?? "-")")
                            continuation.yield(event)
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
        struct Body: Encodable {
            struct Attrs: Encodable { let isOn: Bool }
            let attributes: Attrs
        }
        // Dirigera expects an array of patch operations, not a bare object.
        let body = try JSONEncoder().encode([Body(attributes: .init(isOn: isOn))])
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
