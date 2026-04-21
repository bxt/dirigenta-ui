import Foundation

struct DirigeraDevice: Identifiable, Decodable {
    let id: String
    let type: String
    let deviceType: String?
    let isReachable: Bool?
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
    }

    var displayName: String { attributes.customName ?? id }
    var isOn: Bool { attributes.isOn ?? false }
    var isOpen: Bool { attributes.isOpen ?? false }

    func withIsOn(_ value: Bool) -> DirigeraDevice {
        DirigeraDevice(id: id, type: type, deviceType: deviceType, isReachable: isReachable,
                       attributes: Attributes(customName: attributes.customName, isOn: value,
                                              isOpen: attributes.isOpen,
                                              batteryPercentage: attributes.batteryPercentage,
                                              currentTemperature: attributes.currentTemperature,
                                              currentRH: attributes.currentRH,
                                              currentCO2: attributes.currentCO2,
                                              currentPM25: attributes.currentPM25))
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
