import XCTest
import CryptoKit

@testable import dirigenta_ui

// MARK: - #6  DirigeraAuthClient PKCE generation

final class DirigeraAuthClientTests: XCTestCase {

    // MARK: base64URLEncoded

    func testBase64URLEncoded_noPaddingEquals() {
        // Verify no '=' padding characters appear in output
        let data = Data([0x00, 0x01, 0x02])  // 3 bytes → no padding needed
        XCTAssertFalse(data.base64URLEncoded().contains("="))
    }

    func testBase64URLEncoded_noPlus() {
        // Find bytes that produce '+' in standard base64 → should become '-'
        // 0xFB produces '+' in base64 in certain positions
        let data = Data(repeating: 0xFB, count: 32)
        XCTAssertFalse(data.base64URLEncoded().contains("+"))
    }

    func testBase64URLEncoded_noSlash() {
        // Find bytes that produce '/' in standard base64 → should become '_'
        // 0xFF produces '/' in base64 in certain positions
        let data = Data(repeating: 0xFF, count: 32)
        XCTAssertFalse(data.base64URLEncoded().contains("/"))
    }

    func testBase64URLEncoded_knownVector() {
        // PKCE spec example: SHA-256 hash of "abc" base64url-encoded
        let hash = SHA256.hash(data: Data("abc".utf8))
        let encoded = Data(hash).base64URLEncoded()
        // Standard base64 of SHA-256("abc") = "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
        // URL-safe: replace + with -, / with _, strip =
        XCTAssertEqual(encoded, "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
    }

    func testBase64URLEncoded_onlyURLSafeCharacters() {
        // All 256 possible byte values should produce only URL-safe chars
        let data = Data(0x00...0xFF)
        let encoded = data.base64URLEncoded()
        let urlSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        XCTAssertTrue(encoded.unicodeScalars.allSatisfy { urlSafe.contains($0) })
    }

    // MARK: makeVerifier

    func testMakeVerifier_isURLSafeBase64() {
        let v = DirigeraAuthClient.makeVerifier()
        let urlSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        XCTAssertTrue(v.unicodeScalars.allSatisfy { urlSafe.contains($0) },
                      "verifier must be URL-safe base64")
    }

    func testMakeVerifier_hasExpectedLength() {
        // 32 random bytes base64url-encoded → 43 chars (ceil(32*4/3), no padding)
        XCTAssertEqual(DirigeraAuthClient.makeVerifier().count, 43)
    }

    func testMakeVerifier_isUnique() {
        // Two successive calls should (with overwhelming probability) differ
        let v1 = DirigeraAuthClient.makeVerifier()
        let v2 = DirigeraAuthClient.makeVerifier()
        XCTAssertNotEqual(v1, v2)
    }

    // MARK: makeChallenge

    func testMakeChallenge_matchesSHA256Base64URL() {
        // S256 spec: challenge = BASE64URL(SHA256(ASCII(verifier)))
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = DirigeraAuthClient.makeChallenge(for: verifier)

        let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        XCTAssertEqual(challenge, expected)
    }

    func testMakeChallenge_noEqualsNoPlusNoSlash() {
        let challenge = DirigeraAuthClient.makeChallenge(for: DirigeraAuthClient.makeVerifier())
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }

    // MARK: requestPairing — GET with query params (the hub rejects POST)

    @MainActor
    func testRequestPairing_usesGetWithQueryParams() async throws {
        MockURLProtocol.handler = { request in
            let responseJSON = #"{"code":"test-code"}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (resp, responseJSON.data(using: .utf8)!)
        }
        defer {
            MockURLProtocol.handler = nil
            MockURLProtocol.capturedRequest = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = DirigeraAuthClient(ip: "192.168.1.1", sessionConfiguration: config)
        defer { client.invalidate() }

        let (code, _) = try await client.requestPairing()
        XCTAssertEqual(code, "test-code", "must read the `code` field")

        let request = try XCTUnwrap(MockURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "GET", "authorize must be a GET — the hub rejects POST")
        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(components.path, "/v1/oauth/authorize")
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        XCTAssertEqual(query["audience"], "homesmart.local")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertFalse((query["code_challenge"] ?? "").isEmpty, "must send a code_challenge")
    }

    @MainActor
    func testExchangeToken_sendsFormUrlEncodedBody() async throws {
        MockURLProtocol.handler = { request in
            let responseJSON = #"{"access_token":"bearer-xyz"}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (resp, responseJSON.data(using: .utf8)!)
        }
        defer {
            MockURLProtocol.handler = nil
            MockURLProtocol.capturedRequest = nil
            MockURLProtocol.capturedBody = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = DirigeraAuthClient(ip: "192.168.1.1", sessionConfiguration: config)
        defer { client.invalidate() }

        let token = try await client.exchangeToken(code: "code123", verifier: "verifier456")
        XCTAssertEqual(token, "bearer-xyz")

        let request = try XCTUnwrap(MockURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded",
            "token body must be form-encoded, not JSON"
        )

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        var parsed = URLComponents()
        parsed.percentEncodedQuery = String(data: body, encoding: .utf8)
        var fields: [String: String] = [:]
        for item in parsed.queryItems ?? [] { fields[item.name] = item.value }
        XCTAssertEqual(fields["code"], "code123")
        XCTAssertEqual(fields["code_verifier"], "verifier456")
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertTrue(
            (fields["name"] ?? "").contains("dirigenta-ui"),
            "client name must identify the app"
        )
    }

    // MARK: reachable hub that rejects the request → unexpectedStatus

    @MainActor
    func testRequestPairing_nonOKStatus_throwsUnexpectedStatusNotTransportError()
        async throws
    {
        // A hub that answers with 404 is reachable — the failure must surface
        // as `unexpectedStatus` (so the UI doesn't blame the network), not a
        // URLError. This is the regression the pairing bug exposed.
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (resp, Data("Cannot POST /v1/oauth/authorize".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = DirigeraAuthClient(ip: "192.168.1.1", sessionConfiguration: config)
        defer { client.invalidate() }

        do {
            _ = try await client.requestPairing()
            XCTFail("expected requestPairing to throw on a 404")
        } catch let DirigeraAuthError.unexpectedStatus(code) {
            XCTAssertEqual(code, 404)
        }
    }
}
