import XCTest

@testable import dirigenta_ui

// MARK: - Migration of legacy single-hub Keychain entry into the v2 multi-hub format
//
// The pre-multi-hub build stored credentials under the key "dirigeraHub" as
// `{ accessToken, hubFingerprint }`. The new build expects an array of `Hub`
// at "dirigeraHubs.v2". On first launch we read the legacy entry, wrap it in
// a single `Hub`, fold in the global `pinnedLightId` / `settings.pinnedRoomId`
// UserDefaults values, and (when not in test injection mode) write back +
// delete the legacy entry. These tests pin the read path against the in-memory
// store; the write-back path is exercised in production on first launch.

@MainActor
final class AppStateMultiHubMigrationTests: XCTestCase {

    private let legacyKey = "dirigeraHub"
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

    // MARK: Legacy → v2 promotion

    func testMigration_legacyEntry_promotedToHubsArray() throws {
        try store.set(
            #"{"accessToken":"legacy-token","hubFingerprint":"legacy-fp"}"#,
            for: legacyKey
        )

        let state = makeState()
        XCTAssertEqual(state.hubs.count, 1)
        XCTAssertEqual(state.selectedHub?.accessToken, "legacy-token")
        XCTAssertEqual(state.selectedHub?.hubFingerprint, "legacy-fp")
    }

    func testMigration_legacyEntry_kindIsReal() throws {
        try store.set(#"{"accessToken":"tok"}"#, for: legacyKey)
        let state = makeState()
        XCTAssertEqual(state.selectedHub?.kind, .real)
    }

    func testMigration_legacyEntry_displayNameDefault() throws {
        try store.set(#"{"accessToken":"tok"}"#, for: legacyKey)
        let state = makeState()
        XCTAssertEqual(state.selectedHub?.displayName, "My Hub")
    }

    func testMigration_legacyEntry_selectsTheMigratedHub() throws {
        try store.set(#"{"accessToken":"tok"}"#, for: legacyKey)
        let state = makeState()
        XCTAssertEqual(state.selectedHubID, state.hubs.first?.id)
    }

    func testMigration_legacyEntry_withoutFingerprint() throws {
        try store.set(#"{"accessToken":"only-token"}"#, for: legacyKey)
        let state = makeState()
        XCTAssertEqual(state.selectedHub?.accessToken, "only-token")
        XCTAssertNil(state.selectedHub?.hubFingerprint)
    }

    // MARK: v2 takes precedence over legacy

    func testMigration_v2Present_takesPrecedenceOverLegacy() throws {
        let v2Hub = Hub.real(displayName: "From v2", accessToken: "v2-token")
        let v2Json = try XCTUnwrap(
            String(data: try JSONEncoder().encode([v2Hub]), encoding: .utf8)
        )
        try store.set(v2Json, for: v2Key)
        try store.set(#"{"accessToken":"legacy-token"}"#, for: legacyKey)

        let state = makeState()
        XCTAssertEqual(state.hubs.count, 1)
        XCTAssertEqual(state.selectedHub?.accessToken, "v2-token")
    }

    // MARK: Empty / corrupt store

    func testMigration_noLegacyAndNoV2_emptyHubs() {
        let state = makeState()
        XCTAssertTrue(state.hubs.isEmpty)
        XCTAssertNil(state.selectedHubID)
    }

    func testMigration_corruptLegacy_yieldsEmptyHubs() throws {
        try store.set("{not json", for: legacyKey)
        let state = makeState()
        XCTAssertTrue(state.hubs.isEmpty)
    }

    // MARK: Selected hub id round-trip

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
        UserDefaults.standard.set(
            UUID().uuidString,
            forKey: "selectedHubID"
        )
        defer { UserDefaults.standard.removeObject(forKey: "selectedHubID") }

        let state = makeState()
        XCTAssertEqual(state.selectedHubID, hub.id)
    }
}
