import XCTest

@testable import dirigenta_ui

// MARK: - Re-pair recovery for a rotated hub TLS certificate
//
// When a hub's leaf certificate rotates (firmware update / factory reset /
// hardware swap), the pinned fingerprint stops matching and the hub must be
// re-paired. `addOrUpdateHub(replacing:)` updates the existing hub in place
// instead of appending a duplicate, half-configured entry — and the captured
// fingerprint won't match the stored one, so the plain add path can't do this
// on its own.

@MainActor
final class AppStateRePairTests: XCTestCase {

    private func makeState() -> AppState {
        AppState(
            credentialStore: InMemoryCredentialStore(),
            mdns: MDNSResolver(networkingEnabled: false)
        )
    }

    func testReplacing_updatesInPlaceWithoutDuplicating() {
        let state = makeState()
        var hub = Hub.real(
            displayName: "Home",
            accessToken: "old-token",
            hubFingerprint: "old-fp"
        )
        hub.pinnedDeviceId = "lamp-1"
        hub.pinnedRoomId = "room-1"
        hub.lastKnownIP = "192.168.1.50"
        state.hubs = [hub]
        state.selectedHubID = hub.id

        state.addOrUpdateHub(
            token: "new-token",
            hubFingerprint: "new-fp",
            gatewayName: nil,
            replacing: hub.id
        )

        XCTAssertEqual(state.hubs.count, 1, "must not create a duplicate hub")
        let updated = state.hubs[0]
        XCTAssertEqual(updated.id, hub.id, "hub identity preserved")
        XCTAssertEqual(updated.accessToken, "new-token")
        XCTAssertEqual(updated.hubFingerprint, "new-fp")
        XCTAssertEqual(updated.pinnedDeviceId, "lamp-1", "preferences preserved")
        XCTAssertEqual(updated.pinnedRoomId, "room-1")
        XCTAssertEqual(updated.lastKnownIP, "192.168.1.50")
    }

    func testWithoutReplacing_certRotation_appendsDuplicate() {
        // Documents the gap the `replacing:` path closes: a fresh fingerprint
        // doesn't match the stored one, so the plain add path can't recognize
        // the same hub and appends a second entry.
        let state = makeState()
        let hub = Hub.real(
            displayName: "Home",
            accessToken: "old",
            hubFingerprint: "old-fp"
        )
        state.hubs = [hub]
        state.selectedHubID = hub.id

        state.addOrUpdateHub(
            token: "new",
            hubFingerprint: "new-fp",
            gatewayName: nil
        )

        XCTAssertEqual(state.hubs.count, 2)
    }

    func testReplacing_clearsCertificateMismatchState() {
        let state = makeState()
        let hub = Hub.real(
            displayName: "Home",
            accessToken: "tok",
            hubFingerprint: "fp"
        )
        state.hubs = [hub]
        state.selectedHubID = hub.id
        state.certificateMismatchHubID = hub.id

        state.addOrUpdateHub(
            token: "tok2",
            hubFingerprint: "fp2",
            gatewayName: nil,
            replacing: hub.id
        )

        XCTAssertNil(state.certificateMismatchHubID)
    }

    func testReplacing_clearsAuthFailedState() {
        let state = makeState()
        let hub = Hub.real(
            displayName: "Home",
            accessToken: "tok",
            hubFingerprint: "fp"
        )
        state.hubs = [hub]
        state.selectedHubID = hub.id
        state.authFailedHubID = hub.id

        state.addOrUpdateHub(
            token: "tok2",
            hubFingerprint: nil,
            gatewayName: nil,
            replacing: hub.id
        )

        XCTAssertNil(state.authFailedHubID)
    }

    func testReplacing_manualToken_clearsStaleFingerprint() {
        // A manual-token re-pair carries no captured fingerprint; clearing the
        // stale pin lets the next connection re-capture the new leaf cert via
        // trust-on-first-use.
        let state = makeState()
        let hub = Hub.real(
            displayName: "Home",
            accessToken: "old",
            hubFingerprint: "old-fp"
        )
        state.hubs = [hub]
        state.selectedHubID = hub.id

        state.addOrUpdateHub(
            token: "new",
            hubFingerprint: nil,
            gatewayName: nil,
            replacing: hub.id
        )

        XCTAssertEqual(state.hubs.count, 1)
        XCTAssertNil(state.hubs[0].hubFingerprint)
        XCTAssertEqual(state.hubs[0].accessToken, "new")
    }

    func testReplacing_unknownID_fallsBackToAppend() {
        let state = makeState()
        state.hubs = []
        state.selectedHubID = nil

        state.addOrUpdateHub(
            token: "tok",
            hubFingerprint: "fp",
            gatewayName: "Hub",
            replacing: UUID()
        )

        XCTAssertEqual(state.hubs.count, 1)
        XCTAssertEqual(state.hubs[0].hubFingerprint, "fp")
    }

    // MARK: - noteMutationError escalates auth/trust failures

    func testNoteMutationError_unauthorized_setsAuthFailedState() {
        let state = makeState()
        let hub = Hub.real(displayName: "Home", accessToken: "tok")
        state.hubs = [hub]
        state.selectedHubID = hub.id

        state.noteMutationError(DirigeraAPIError.unauthorized)

        XCTAssertEqual(state.authFailedHubID, hub.id)
        XCTAssertEqual(
            state.devicesError,
            "Authentication failed — re-pair the hub"
        )
    }

    func testNoteMutationError_certificateMismatch_setsCertState() {
        let state = makeState()
        let hub = Hub.real(displayName: "Home", accessToken: "tok")
        state.hubs = [hub]
        state.selectedHubID = hub.id

        state.noteMutationError(DirigeraAPIError.certificateMismatch)

        XCTAssertEqual(state.certificateMismatchHubID, hub.id)
    }

    func testNoteMutationError_transportError_ignored() {
        // A transient network error must NOT raise the hub-level re-pair banner;
        // local per-control error handling covers it.
        let state = makeState()
        let hub = Hub.real(displayName: "Home", accessToken: "tok")
        state.hubs = [hub]
        state.selectedHubID = hub.id

        state.noteMutationError(URLError(.timedOut))

        XCTAssertNil(state.authFailedHubID)
        XCTAssertNil(state.certificateMismatchHubID)
        XCTAssertNil(state.devicesError)
    }
}
