import Foundation

enum HubKind: String, Codable { case real, demo }

/// A paired Dirigera hub (real) or the built-in demo hub.
/// Persisted as JSON in the Keychain under "dirigeraHubs.v2".
struct Hub: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var kind: HubKind

    // Real-hub fields. Nil for demo.
    var accessToken: String?
    var hubFingerprint: String?  // base64-encoded SHA-256 of the hub's leaf TLS cert

    // Per-hub preferences — IDs reference devices/rooms that only exist on this hub.
    var pinnedLightId: String?
    var pinnedRoomId: String?

    // Diagnostics surfaced in the per-hub Settings detail.
    var lastKnownIP: String?
    var lastConnectedAt: Date?

    /// Fixed UUID for the singleton demo hub so it can be added/removed idempotently.
    static let demoID = UUID(uuidString: "DE000000-0000-0000-0000-000000000001")!

    static func real(
        id: UUID = UUID(),
        displayName: String,
        accessToken: String,
        hubFingerprint: String? = nil
    ) -> Hub {
        Hub(
            id: id,
            displayName: displayName,
            kind: .real,
            accessToken: accessToken,
            hubFingerprint: hubFingerprint
        )
    }

    static func demo() -> Hub {
        Hub(id: demoID, displayName: "Demo Hub", kind: .demo)
    }
}
