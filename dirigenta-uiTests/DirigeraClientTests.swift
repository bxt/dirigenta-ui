import XCTest

@testable import dirigenta_ui

// MARK: - URLProtocol stub

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?
    /// All requests captured in order; useful when a single test triggers multiple network calls.
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest
    { request }

    override func startLoading() {
        MockURLProtocol.capturedRequest = request
        MockURLProtocol.capturedRequests.append(request)
        // URLSession converts httpBody → httpBodyStream before the protocol sees it.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n > 0 { data.append(buf, count: n) }
            }
            buf.deallocate()
            stream.close()
            MockURLProtocol.capturedBody = data.isEmpty ? nil : data
            MockURLProtocol.capturedBodies.append(data.isEmpty ? nil : data)
        } else {
            MockURLProtocol.capturedBody = request.httpBody
            MockURLProtocol.capturedBodies.append(request.httpBody)
        }
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func httpResponse(status: Int, for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    )!
}

private let testIP = "192.168.1.1"
private let testToken = "test-token"
private let devicesURL = URL(string: "https://\(testIP):8443/v1/devices")!

private let singleDeviceJSON = """
    [{
      "id": "light-1",
      "type": "light",
      "deviceType": "colorTemperatureLight",
      "isReachable": true,
      "attributes": {"customName": "Desk Lamp", "isOn": true, "lightLevel": 80}
    }]
    """

// MARK: - Tests

@MainActor
final class DirigeraClientTests: XCTestCase {

    private var client: DirigeraClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.capturedRequest = nil
        MockURLProtocol.capturedBody = nil
        MockURLProtocol.capturedRequests = []
        MockURLProtocol.capturedBodies = []
        client = DirigeraClient(
            ip: testIP,
            token: testToken,
            session: mockSession()
        )
    }

    // MARK: fetchAllDevices

    func testFetchAllDevices_returnsDecodedDevices() async throws {
        MockURLProtocol.handler = { _ in
            (
                httpResponse(status: 200, for: devicesURL),
                singleDeviceJSON.data(using: .utf8)!
            )
        }
        let devices = try await client.fetchAllDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "light-1")
        XCTAssertEqual(devices[0].attributes.customName, "Desk Lamp")
        XCTAssertEqual(devices[0].attributes.lightLevel, 80)
        XCTAssertEqual(devices[0].attributes.isOn, true)
    }

    func testFetchAllDevices_emptyArray() async throws {
        MockURLProtocol.handler = { _ in
            (
                httpResponse(status: 200, for: devicesURL),
                "[]".data(using: .utf8)!
            )
        }
        let devices = try await client.fetchAllDevices()
        XCTAssertTrue(devices.isEmpty)
    }

    func testFetchAllDevices_httpError_throwsBadServerResponse() async throws {
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 401, for: devicesURL), nil)
        }
        do {
            _ = try await client.fetchAllDevices()
            XCTFail("Expected URLError(.badServerResponse)")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    func testFetchAllDevices_malformedJSON_throwsDecodingError() async throws {
        MockURLProtocol.handler = { _ in
            (
                httpResponse(status: 200, for: devicesURL),
                "not json".data(using: .utf8)!
            )
        }
        do {
            _ = try await client.fetchAllDevices()
            XCTFail("Expected DecodingError")
        } catch is DecodingError {
            // expected
        }
    }

    func testFetchAllDevices_sendsAuthorizationHeader() async throws {
        MockURLProtocol.handler = { _ in
            (
                httpResponse(status: 200, for: devicesURL),
                "[]".data(using: .utf8)!
            )
        }
        _ = try await client.fetchAllDevices()
        let auth = MockURLProtocol.capturedRequest?.value(
            forHTTPHeaderField: "Authorization"
        )
        XCTAssertEqual(auth, "Bearer \(testToken)")
    }

    // MARK: setLight

    func testSetLight_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 200, for: url), nil)
        }

        try await client.setLight(id: "lamp-1", isOn: false)

        let req = try XCTUnwrap(MockURLProtocol.capturedRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.url?.path, "/v1/devices/lamp-1")
        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        )
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["isOn"] as? Bool, false)
    }

    func testSetLight_httpError_throws() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 500, for: url), nil)
        }
        do {
            try await client.setLight(id: "lamp-1", isOn: true)
            XCTFail("Expected URLError(.badServerResponse)")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    // MARK: setLightLevel

    func testSetLightLevel_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 200, for: url), nil)
        }

        try await client.setLightLevel(id: "lamp-1", lightLevel: 75)

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        )
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["lightLevel"] as? Int, 75)
    }

    // MARK: setColorTemperature

    func testSetColorTemperature_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 200, for: url), nil)
        }

        try await client.setColorTemperature(
            id: "lamp-1",
            colorTemperature: 3000
        )

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        )
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["colorTemperature"] as? Int, 3000)
    }

    // MARK: setColor

    func testSetColor_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 200, for: url), nil)
        }

        try await client.setColor(id: "lamp-1", hue: 200.0, saturation: 0.6)

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        )
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(
            attrs["colorHue"] as? Double ?? 0,
            200.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            attrs["colorSaturation"] as? Double ?? 0,
            0.6,
            accuracy: 0.001
        )
    }
}

// MARK: - #8  DirigeraClient.applyColorPreset request ordering

@MainActor
final class ApplyColorPresetTests: XCTestCase {

    private var client: DirigeraClient!
    private let anyURL = URL(string: "https://192.168.1.1:8443/v1/devices/l1")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.capturedRequests = []
        MockURLProtocol.capturedBodies = []
        client = DirigeraClient(ip: "192.168.1.1", token: "tok", session: mockSession())
    }

    private func okHandler(_ request: URLRequest) throws -> (HTTPURLResponse, Data?) {
        (httpResponse(status: 200, for: anyURL), nil)
    }

    private func attrs(from body: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        )
        return try XCTUnwrap(json.first?["attributes"] as? [String: Any])
    }

    // MARK: color preset → setColor first, then setLightLevel

    func testApplyColorPreset_colorPreset_sendsColorThenLevel() async throws {
        MockURLProtocol.handler = okHandler
        let preset = LightColorPreset(lightLevel: 80, hue: 120.0, saturation: 1.0)
        try await client.applyColorPreset(preset, to: "l1")

        XCTAssertEqual(MockURLProtocol.capturedBodies.count, 2, "expect 2 PATCH requests")

        let first = try XCTUnwrap(MockURLProtocol.capturedBodies[0])
        let a1 = try attrs(from: first)
        XCTAssertNotNil(a1["colorHue"], "first request must be setColor")

        let second = try XCTUnwrap(MockURLProtocol.capturedBodies[1])
        let a2 = try attrs(from: second)
        XCTAssertNotNil(a2["lightLevel"], "second request must be setLightLevel")
    }

    // MARK: CT preset → setColorTemperature first, then setLightLevel

    func testApplyColorPreset_ctPreset_sendsCTThenLevel() async throws {
        MockURLProtocol.handler = okHandler
        let preset = LightColorPreset(lightLevel: 60, colorTemperature: 3000)
        try await client.applyColorPreset(preset, to: "l1")

        XCTAssertEqual(MockURLProtocol.capturedBodies.count, 2)

        let first = try XCTUnwrap(MockURLProtocol.capturedBodies[0])
        let a1 = try attrs(from: first)
        XCTAssertNotNil(a1["colorTemperature"], "first request must be setColorTemperature")

        let second = try XCTUnwrap(MockURLProtocol.capturedBodies[1])
        let a2 = try attrs(from: second)
        XCTAssertNotNil(a2["lightLevel"], "second request must be setLightLevel")
    }

    // MARK: level-only preset → only one request

    func testApplyColorPreset_levelOnlyPreset_sendsOnlyLevelRequest() async throws {
        MockURLProtocol.handler = okHandler
        let preset = LightColorPreset(lightLevel: 50)
        try await client.applyColorPreset(preset, to: "l1")

        XCTAssertEqual(MockURLProtocol.capturedBodies.count, 1)
        let body = try XCTUnwrap(MockURLProtocol.capturedBodies[0])
        let a = try attrs(from: body)
        XCTAssertNotNil(a["lightLevel"])
        XCTAssertNil(a["colorHue"])
        XCTAssertNil(a["colorTemperature"])
    }

    // MARK: color-only preset (nil level) → only one request

    func testApplyColorPreset_colorNoLevel_sendsOnlyColorRequest() async throws {
        MockURLProtocol.handler = okHandler
        let preset = LightColorPreset(lightLevel: nil, hue: 30.0, saturation: 0.5)
        try await client.applyColorPreset(preset, to: "l1")

        XCTAssertEqual(MockURLProtocol.capturedBodies.count, 1)
        let body = try XCTUnwrap(MockURLProtocol.capturedBodies[0])
        let a = try attrs(from: body)
        XCTAssertNotNil(a["colorHue"])
        XCTAssertNil(a["lightLevel"])
    }

    // MARK: color value correctness

    func testApplyColorPreset_colorPreset_sendsCorrectHueAndSaturation() async throws {
        MockURLProtocol.handler = okHandler
        let preset = LightColorPreset(lightLevel: nil, hue: 200.5, saturation: 0.75)
        try await client.applyColorPreset(preset, to: "l1")

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies[0])
        let a = try attrs(from: body)
        XCTAssertEqual(a["colorHue"] as? Double ?? 0, 200.5, accuracy: 0.001)
        XCTAssertEqual(a["colorSaturation"] as? Double ?? 0, 0.75, accuracy: 0.001)
    }
}
