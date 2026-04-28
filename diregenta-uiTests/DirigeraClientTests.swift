import XCTest
@testable import diregenta_ui

// MARK: - URLProtocol stub

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedRequest = request
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
        } else {
            MockURLProtocol.capturedBody = request.httpBody
        }
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
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
        client = DirigeraClient(ip: testIP, token: testToken, session: mockSession())
    }

    // MARK: fetchAllDevices

    func testFetchAllDevices_returnsDecodedDevices() async throws {
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 200, for: devicesURL), singleDeviceJSON.data(using: .utf8)!)
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
            (httpResponse(status: 200, for: devicesURL), "[]".data(using: .utf8)!)
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
            (httpResponse(status: 200, for: devicesURL), "not json".data(using: .utf8)!)
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
            (httpResponse(status: 200, for: devicesURL), "[]".data(using: .utf8)!)
        }
        _ = try await client.fetchAllDevices()
        let auth = MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer \(testToken)")
    }

    // MARK: setLight

    func testSetLight_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in (httpResponse(status: 200, for: url), nil) }

        try await client.setLight(id: "lamp-1", isOn: false)

        let req = try XCTUnwrap(MockURLProtocol.capturedRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.url?.path, "/v1/devices/lamp-1")
        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["isOn"] as? Bool, false)
    }

    func testSetLight_httpError_throws() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in (httpResponse(status: 500, for: url), nil) }
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
        MockURLProtocol.handler = { _ in (httpResponse(status: 200, for: url), nil) }

        try await client.setLightLevel(id: "lamp-1", lightLevel: 75)

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["lightLevel"] as? Int, 75)
    }

    // MARK: setColorTemperature

    func testSetColorTemperature_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in (httpResponse(status: 200, for: url), nil) }

        try await client.setColorTemperature(id: "lamp-1", colorTemperature: 3000)

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["colorTemperature"] as? Int, 3000)
    }

    // MARK: setColor

    func testSetColor_sendsCorrectBody() async throws {
        let url = URL(string: "https://\(testIP):8443/v1/devices/lamp-1")!
        MockURLProtocol.handler = { _ in (httpResponse(status: 200, for: url), nil) }

        try await client.setColor(id: "lamp-1", hue: 200.0, saturation: 0.6)

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let attrs = try XCTUnwrap(json.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["colorHue"] as? Double ?? 0, 200.0, accuracy: 0.001)
        XCTAssertEqual(attrs["colorSaturation"] as? Double ?? 0, 0.6, accuracy: 0.001)
    }
}
