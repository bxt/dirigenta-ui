import XCTest

@testable import dirigenta_ui

// MARK: - #12  HubCredentials storage round-trip
//
// Most coverage runs against an in-memory CredentialStore so we don't depend
// on the real Keychain (which fails on unsigned CI binaries due to ACL bound
// to code-signing identity). One integration class still hits the real
// Keychain — it's skipped on CI and runs locally to verify the wrapper.

// MARK: - In-memory store CRUD

final class CredentialStoreTests: XCTestCase {

    private var store: InMemoryCredentialStore!
    private let key = "dirigenta.test.key"

    override func setUp() {
        super.setUp()
        store = InMemoryCredentialStore()
    }

    func testSet_thenGet_returnsOriginalValue() throws {
        try store.set("hello-store", for: key)
        let retrieved = try XCTUnwrap(store.get(key))
        XCTAssertEqual(retrieved, "hello-store")
    }

    func testGet_missingKey_returnsNil() throws {
        XCTAssertNil(try store.get(key))
    }

    func testSet_updatesExistingValue() throws {
        try store.set("first", for: key)
        try store.set("second", for: key)
        XCTAssertEqual(try store.get(key), "second")
    }

    func testDelete_removesValue() throws {
        try store.set("to-be-deleted", for: key)
        try store.delete(key)
        XCTAssertNil(try store.get(key))
    }

    func testDelete_missingKey_doesNotThrow() {
        XCTAssertNoThrow(try store.delete(key))
    }

    func testSet_preservesUTF8SpecialCharacters() throws {
        let value = "tøken-123 🔑 <&>"
        try store.set(value, for: key)
        XCTAssertEqual(try store.get(key), value)
    }

    // MARK: JSON credential blob round-trip (HubCredentials format)

    func testRoundTrip_credentialJSON_tokenOnly() throws {
        let json = #"{"accessToken":"my-bearer-token"}"#
        try store.set(json, for: key)
        let raw = try XCTUnwrap(store.get(key))
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as? [String: String]
        )
        XCTAssertEqual(dict["accessToken"], "my-bearer-token")
        XCTAssertNil(dict["hubFingerprint"])
    }

    func testRoundTrip_credentialJSON_withFingerprint() throws {
        let fp = Data(repeating: 0xAB, count: 32).base64EncodedString()
        let json = #"{"accessToken":"tok","hubFingerprint":"\#(fp)"}"#
        try store.set(json, for: key)
        let raw = try XCTUnwrap(store.get(key))
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as? [String: String]
        )
        XCTAssertEqual(dict["accessToken"], "tok")
        XCTAssertEqual(dict["hubFingerprint"], fp)
    }
}

// MARK: - AppState reads CredentialStore on init

@MainActor
final class AppStateCredentialInitTests: XCTestCase {

    private let key = "dirigeraHub"
    private var store: InMemoryCredentialStore!

    override func setUp() {
        super.setUp()
        store = InMemoryCredentialStore()
    }

    private func makeState() -> AppState {
        AppState(
            credentialStore: store,
            mdns: MDNSResolver(networkingEnabled: false)
        )
    }

    func testInit_readsAccessTokenFromStore() throws {
        let json = #"{"accessToken":"keychain-token-123"}"#
        try store.set(json, for: key)

        let state = makeState()
        XCTAssertEqual(state.accessToken, "keychain-token-123")
    }

    func testInit_readsFingerprintFromStore() throws {
        let fingerprint = Data(repeating: 0xBC, count: 32)
        let fp = fingerprint.base64EncodedString()
        let json = #"{"accessToken":"tok","hubFingerprint":"\#(fp)"}"#
        try store.set(json, for: key)

        let state = makeState()
        XCTAssertEqual(state.hubCertFingerprint, fingerprint)
    }

    func testInit_emptyToken_whenStoreEmpty() {
        let state = makeState()
        XCTAssertEqual(state.accessToken, "")
        XCTAssertNil(state.hubCertFingerprint)
    }

    func testInit_gracefullyHandlesMalformedJSON() throws {
        try store.set("not-valid-json", for: key)
        let state = makeState()
        XCTAssertEqual(state.accessToken, "")
    }
}

// MARK: - Real Keychain integration (local-only)
//
// Verifies the KeychainService wrapper actually talks to SecItem* correctly.
// Skipped on CI because:
//  • CI builds with CODE_SIGNING_ALLOWED=NO → no stable code-signing identity
//  • Keychain item ACLs are bound to that identity → reads/updates/deletes
//    against an item the unsigned binary itself created can return
//    errSecAuthFailed or trigger a UI prompt that hangs the runner.

final class KeychainServiceIntegrationTests: XCTestCase {

    private let key = "dirigenta.test.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipped on CI: real Keychain access is unreliable for unsigned binaries"
        )
        // Best-effort canary so we still skip if the local Keychain is locked.
        do {
            try KeychainService.set("canary", for: key)
            try KeychainService.delete(key)
        } catch {
            throw XCTSkip("Keychain not accessible: \(error)")
        }
    }

    override func tearDown() {
        try? KeychainService.delete(key)
        super.tearDown()
    }

    func testRealKeychain_setGetDelete_roundTrip() throws {
        try KeychainService.set("hello-keychain", for: key)
        XCTAssertEqual(try KeychainService.get(key), "hello-keychain")

        try KeychainService.set("updated", for: key)
        XCTAssertEqual(try KeychainService.get(key), "updated")

        try KeychainService.delete(key)
        XCTAssertNil(try KeychainService.get(key))
    }

    func testRealKeychain_deleteMissingKey_doesNotThrow() {
        XCTAssertNoThrow(try KeychainService.delete(key))
    }
}
