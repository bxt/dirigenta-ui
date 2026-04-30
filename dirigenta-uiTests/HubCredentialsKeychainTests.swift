import XCTest

@testable import dirigenta_ui

// MARK: - #12  HubCredentials Keychain round-trip

// Tests exercise KeychainService directly (the storage layer) and verify that
// AppState correctly reads credentials back from Keychain on init.

// MARK: - KeychainService CRUD tests

final class KeychainServiceTests: XCTestCase {

    // Use a test-only key so we never touch the real app credential.
    private let key = "dirigenta.test.\(UUID().uuidString)"

    override func tearDown() {
        try? KeychainService.delete(key)
        super.tearDown()
    }

    // MARK: Basic round-trip

    func testSet_thenGet_returnsOriginalValue() throws {
        try KeychainService.set("hello-keychain", for: key)
        let retrieved = try XCTUnwrap(KeychainService.get(key))
        XCTAssertEqual(retrieved, "hello-keychain")
    }

    func testGet_missingKey_returnsNil() throws {
        let result = try KeychainService.get(key)
        XCTAssertNil(result)
    }

    func testSet_updatesExistingValue() throws {
        try KeychainService.set("first", for: key)
        try KeychainService.set("second", for: key)
        let result = try XCTUnwrap(KeychainService.get(key))
        XCTAssertEqual(result, "second")
    }

    func testDelete_removesValue() throws {
        try KeychainService.set("to-be-deleted", for: key)
        try KeychainService.delete(key)
        let result = try KeychainService.get(key)
        XCTAssertNil(result)
    }

    func testDelete_missingKey_doesNotThrow() {
        // Deleting a key that doesn't exist must be silent (errSecItemNotFound handled).
        XCTAssertNoThrow(try KeychainService.delete(key))
    }

    func testSet_preservesUTF8SpecialCharacters() throws {
        let value = "tøken-123 🔑 <&>"
        try KeychainService.set(value, for: key)
        let retrieved = try XCTUnwrap(KeychainService.get(key))
        XCTAssertEqual(retrieved, value)
    }

    // MARK: JSON credential blob round-trip (HubCredentials format)

    func testRoundTrip_credentialJSON_tokenOnly() throws {
        // Replicate what AppState.saveCredentials encodes (without the private type).
        let json = #"{"accessToken":"my-bearer-token"}"#
        try KeychainService.set(json, for: key)
        let raw = try XCTUnwrap(KeychainService.get(key))
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as? [String: String]
        )
        XCTAssertEqual(dict["accessToken"], "my-bearer-token")
        XCTAssertNil(dict["hubFingerprint"])
    }

    func testRoundTrip_credentialJSON_withFingerprint() throws {
        let fp = Data(repeating: 0xAB, count: 32).base64EncodedString()
        let json = #"{"accessToken":"tok","hubFingerprint":"\#(fp)"}"#
        try KeychainService.set(json, for: key)
        let raw = try XCTUnwrap(KeychainService.get(key))
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as? [String: String]
        )
        XCTAssertEqual(dict["accessToken"], "tok")
        XCTAssertEqual(dict["hubFingerprint"], fp)
    }
}

// MARK: - AppState reads Keychain on init

@MainActor
final class AppStateKeychainInitTests: XCTestCase {

    private let keychainKey = "dirigeraHub"

    override func setUp() async throws {
        try await super.setUp()
        // Snapshot whatever is in Keychain so we can restore it after the test.
        // In CI there is nothing there; locally the developer might have a real token.
        try? KeychainService.delete(keychainKey)
    }

    override func tearDown() {
        try? KeychainService.delete(keychainKey)
        super.tearDown()
    }

    func testInit_readsAccessTokenFromKeychain() throws {
        // Store a credential blob the same way AppState.saveCredentials would.
        let json = #"{"accessToken":"keychain-token-123"}"#
        try KeychainService.set(json, for: keychainKey)

        let state = AppState()
        XCTAssertEqual(state.accessToken, "keychain-token-123")
    }

    func testInit_readsFingerprintFromKeychain() throws {
        let fingerprint = Data(repeating: 0xBC, count: 32)
        let fp = fingerprint.base64EncodedString()
        let json = #"{"accessToken":"tok","hubFingerprint":"\#(fp)"}"#
        try KeychainService.set(json, for: keychainKey)

        let state = AppState()
        XCTAssertEqual(state.hubCertFingerprint, fingerprint)
    }

    func testInit_emptyToken_whenKeychainEmpty() {
        // Delete the key right before constructing AppState in case another
        // test class (e.g. AppStateMakeClientTests) wrote to it concurrently.
        try? KeychainService.delete(keychainKey)
        // No Keychain entry → accessToken must be ""
        let state = AppState()
        XCTAssertEqual(state.accessToken, "")
        XCTAssertNil(state.hubCertFingerprint)
    }

    func testInit_gracefullyHandlesMalformedJSON() throws {
        // Corrupt Keychain entry → falls back to empty token (no crash)
        try KeychainService.set("not-valid-json", for: keychainKey)
        let state = AppState()
        XCTAssertEqual(state.accessToken, "")
    }
}
