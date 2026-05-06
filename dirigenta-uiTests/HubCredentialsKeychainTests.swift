import XCTest

@testable import dirigenta_ui

// MARK: - #12  Credential storage round-trip
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

    // MARK: Hub array JSON round-trip (v2 storage format)

    func testRoundTrip_hubArray_singleRealHub() throws {
        let hub = Hub.real(
            displayName: "Living Room",
            accessToken: "tok",
            hubFingerprint: "fp"
        )
        let data = try JSONEncoder().encode([hub])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        try store.set(json, for: "dirigeraHubs.v2")

        let raw = try XCTUnwrap(try store.get("dirigeraHubs.v2"))
        let decoded = try JSONDecoder().decode(
            [Hub].self,
            from: raw.data(using: .utf8)!
        )
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].displayName, "Living Room")
        XCTAssertEqual(decoded[0].accessToken, "tok")
        XCTAssertEqual(decoded[0].hubFingerprint, "fp")
        XCTAssertEqual(decoded[0].kind, .real)
    }

    func testRoundTrip_hubArray_multipleHubs() throws {
        let hubs = [
            Hub.real(displayName: "Home", accessToken: "tok-1", hubFingerprint: "fp-1"),
            Hub.real(displayName: "Cottage", accessToken: "tok-2", hubFingerprint: "fp-2"),
        ]
        let data = try JSONEncoder().encode(hubs)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        try store.set(json, for: "dirigeraHubs.v2")

        let raw = try XCTUnwrap(try store.get("dirigeraHubs.v2"))
        let decoded = try JSONDecoder().decode(
            [Hub].self,
            from: raw.data(using: .utf8)!
        )
        XCTAssertEqual(decoded.map(\.displayName), ["Home", "Cottage"])
    }
}

// MARK: - AppState reads CredentialStore on init

@MainActor
final class AppStateCredentialInitTests: XCTestCase {

    private let v2Key = "dirigeraHubs.v2"
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

    func testInit_readsHubsFromV2Store() throws {
        let hub = Hub.real(
            displayName: "Home",
            accessToken: "keychain-token-123",
            hubFingerprint: nil
        )
        let json = try XCTUnwrap(
            String(data: try JSONEncoder().encode([hub]), encoding: .utf8)
        )
        try store.set(json, for: v2Key)

        let state = makeState()
        XCTAssertEqual(state.hubs.count, 1)
        XCTAssertEqual(state.selectedHub?.accessToken, "keychain-token-123")
    }

    func testInit_readsFingerprintFromStore() throws {
        let fingerprint = Data(repeating: 0xBC, count: 32)
        let fp = fingerprint.base64EncodedString()
        let hub = Hub.real(
            displayName: "Home",
            accessToken: "tok",
            hubFingerprint: fp
        )
        let json = try XCTUnwrap(
            String(data: try JSONEncoder().encode([hub]), encoding: .utf8)
        )
        try store.set(json, for: v2Key)

        let state = makeState()
        XCTAssertEqual(state.selectedHub?.hubFingerprint, fp)
    }

    func testInit_emptyHubs_whenStoreEmpty() {
        let state = makeState()
        XCTAssertTrue(state.hubs.isEmpty)
        XCTAssertNil(state.selectedHubID)
    }

    func testInit_gracefullyHandlesMalformedJSON() throws {
        try store.set("not-valid-json", for: v2Key)
        let state = makeState()
        XCTAssertTrue(state.hubs.isEmpty)
    }

    // MARK: Selected hub id is read from UserDefaults

    func testInit_remembersSelectedHubID_whenStillPresent() throws {
        let hub1 = Hub.real(displayName: "Home", accessToken: "tok-1")
        let hub2 = Hub.real(displayName: "Cottage", accessToken: "tok-2")
        let json = try XCTUnwrap(
            String(
                data: try JSONEncoder().encode([hub1, hub2]),
                encoding: .utf8
            )
        )
        try store.set(json, for: v2Key)
        UserDefaults.standard.set(hub2.id.uuidString, forKey: "selectedHubID")
        defer { UserDefaults.standard.removeObject(forKey: "selectedHubID") }

        let state = makeState()
        XCTAssertEqual(state.selectedHubID, hub2.id)
    }

    func testInit_fallsBackToFirstHub_whenStoredSelectedHubIDStale() throws {
        let hub = Hub.real(displayName: "Home", accessToken: "tok")
        let json = try XCTUnwrap(
            String(data: try JSONEncoder().encode([hub]), encoding: .utf8)
        )
        try store.set(json, for: v2Key)
        UserDefaults.standard.set(UUID().uuidString, forKey: "selectedHubID")
        defer { UserDefaults.standard.removeObject(forKey: "selectedHubID") }

        let state = makeState()
        XCTAssertEqual(state.selectedHubID, hub.id)
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
