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

    // MARK: requestPairing body — snake_case JSON keys

    @MainActor
    func testRequestPairing_sendsSnakeCaseKeys() async throws {
        MockURLProtocol.handler = { request in
            let responseJSON = #"{"authorization_code":"test-code"}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (resp, responseJSON.data(using: .utf8)!)
        }
        defer { MockURLProtocol.handler = nil; MockURLProtocol.capturedBody = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = DirigeraAuthClient(ip: "192.168.1.1", sessionConfiguration: config)
        defer { client.invalidate() }

        _ = try await client.requestPairing()

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertNotNil(json["code_challenge"], "must send code_challenge (snake_case)")
        XCTAssertNotNil(json["code_challenge_method"], "must send code_challenge_method (snake_case)")
        XCTAssertNotNil(json["grant_type"], "must send grant_type (snake_case)")
        XCTAssertEqual(json["code_challenge_method"] as? String, "S256")
    }

    @MainActor
    func testExchangeToken_sendsSnakeCaseKeys() async throws {
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
        defer { MockURLProtocol.handler = nil; MockURLProtocol.capturedBody = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = DirigeraAuthClient(ip: "192.168.1.1", sessionConfiguration: config)
        defer { client.invalidate() }

        let token = try await client.exchangeToken(code: "code123", verifier: "verifier456")

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertNotNil(json["code_verifier"], "must send code_verifier (snake_case)")
        XCTAssertNotNil(json["grant_type"], "must send grant_type (snake_case)")
        XCTAssertEqual(json["code"] as? String, "code123")
        XCTAssertEqual(json["code_verifier"] as? String, "verifier456")
        XCTAssertEqual(token, "bearer-xyz")
    }
}
