import Foundation

struct DirigeraDevice: Identifiable, Decodable {
    let id: String
    let type: String
    let isReachable: Bool?
    let attributes: Attributes

    struct Attributes: Decodable {
        let customName: String?
        let isOn: Bool?
    }

    var displayName: String { attributes.customName ?? id }
    var isOn: Bool { attributes.isOn ?? false }
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

    func fetchLights() async throws -> [DirigeraDevice] {
        let data = try await get("/v1/devices")
        let all = try JSONDecoder().decode([DirigeraDevice].self, from: data)
        return all.filter { $0.type == "lightbulb" }
    }

    func setLight(id: String, isOn: Bool) async throws {
        struct Body: Encodable {
            struct Attrs: Encodable { let isOn: Bool }
            let attributes: Attrs
        }
        let body = try JSONEncoder().encode(Body(attributes: .init(isOn: isOn)))
        try await patch("/v1/devices/\(id)", body: body)
    }

    private func get(_ path: String) async throws -> Data {
        var req = try makeRequest(path)
        req.httpMethod = "GET"
        let (data, response) = try await session.data(for: req)
        try validate(response)
        return data
    }

    private func patch(_ path: String, body: Data) async throws {
        var req = try makeRequest(path)
        req.httpMethod = "PATCH"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: req)
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
