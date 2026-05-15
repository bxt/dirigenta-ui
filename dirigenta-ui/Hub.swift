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
    /// Currently pinned device (light or smart plug). Legacy keychain JSON used
    /// the key `pinnedLightId`; reads fall back to it via `init(from:)`.
    var pinnedDeviceId: String?
    var pinnedRoomId: String?

    // Diagnostics surfaced in the per-hub Settings detail.
    var lastKnownIP: String?
    var lastConnectedAt: Date?

    /// Fixed UUID for the singleton demo hub so it can be added/removed idempotently.
    static let demoID = UUID(uuidString: "DE000000-0000-0000-0000-000000000001")!

    /// Display name assigned to a fresh real-hub pairing before we know the
    /// gateway's actual name. Used as a sentinel so the first successful
    /// fetch can auto-upgrade `displayName` to the live `gatewayName`
    /// without overwriting a name the user has already customized.
    static let defaultRealDisplayName = "My Hub"

    // Replaces the synthesized memberwise init (suppressed by the custom init(from:) below).
    init(
        id: UUID = UUID(),
        displayName: String,
        kind: HubKind,
        accessToken: String? = nil,
        hubFingerprint: String? = nil,
        pinnedDeviceId: String? = nil,
        pinnedRoomId: String? = nil,
        lastKnownIP: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.accessToken = accessToken
        self.hubFingerprint = hubFingerprint
        self.pinnedDeviceId = pinnedDeviceId
        self.pinnedRoomId = pinnedRoomId
        self.lastKnownIP = lastKnownIP
        self.lastConnectedAt = lastConnectedAt
    }

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

    /// `true` when this hub can be used immediately — real hubs need an
    /// access token from a completed pairing flow; demo hubs are always
    /// ready since they don't talk to the network.
    var isReady: Bool {
        switch kind {
        case .demo: return true
        case .real: return accessToken != nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, kind
        case accessToken, hubFingerprint
        case pinnedDeviceId, pinnedRoomId
        case lastKnownIP, lastConnectedAt
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case pinnedLightId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decode(HubKind.self, forKey: .kind)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        hubFingerprint = try c.decodeIfPresent(
            String.self, forKey: .hubFingerprint
        )
        pinnedRoomId = try c.decodeIfPresent(String.self, forKey: .pinnedRoomId)
        lastKnownIP = try c.decodeIfPresent(String.self, forKey: .lastKnownIP)
        lastConnectedAt = try c.decodeIfPresent(
            Date.self, forKey: .lastConnectedAt
        )
        // Prefer the new key; fall back to legacy `pinnedLightId` so existing
        // keychain data continues to load. Synthesized encode(to:) uses the
        // new key, so data migrates on the next save.
        if let new = try c.decodeIfPresent(
            String.self, forKey: .pinnedDeviceId
        ) {
            pinnedDeviceId = new
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            pinnedDeviceId = try legacy.decodeIfPresent(
                String.self, forKey: .pinnedLightId
            )
        }
    }
}
