import XCTest

@testable import dirigenta_ui

// Verifies the Hub Codable migration: legacy keychain JSON used the key
// `pinnedLightId`, which now decodes into the renamed `pinnedDeviceId`.
final class HubCodableTests: XCTestCase {

    func testDecode_legacyPinnedLightId_mapsToPinnedDeviceId() throws {
        let legacy = """
            {
              "id": "DE000000-0000-0000-0000-000000000001",
              "displayName": "Old Hub",
              "kind": "real",
              "accessToken": "tok",
              "pinnedLightId": "light-42"
            }
            """
        let hub = try JSONDecoder().decode(
            Hub.self,
            from: legacy.data(using: .utf8)!
        )
        XCTAssertEqual(hub.pinnedDeviceId, "light-42")
    }

    func testDecode_newPinnedDeviceId_isUsedAsIs() throws {
        let json = """
            {
              "id": "DE000000-0000-0000-0000-000000000002",
              "displayName": "New Hub",
              "kind": "real",
              "accessToken": "tok",
              "pinnedDeviceId": "plug-7"
            }
            """
        let hub = try JSONDecoder().decode(
            Hub.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(hub.pinnedDeviceId, "plug-7")
    }

    func testDecode_newKeyTakesPrecedenceOverLegacy() throws {
        // If both keys appear (transitional state during migration), the new key wins.
        let json = """
            {
              "id": "DE000000-0000-0000-0000-000000000003",
              "displayName": "Hub",
              "kind": "real",
              "accessToken": "tok",
              "pinnedDeviceId": "new",
              "pinnedLightId": "legacy"
            }
            """
        let hub = try JSONDecoder().decode(
            Hub.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(hub.pinnedDeviceId, "new")
    }

    func testRoundTrip_writesPinnedDeviceIdKey() throws {
        let hub = Hub(
            id: UUID(),
            displayName: "Hub",
            kind: .real,
            accessToken: "tok",
            pinnedDeviceId: "device-1"
        )
        let data = try JSONEncoder().encode(hub)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"pinnedDeviceId\":\"device-1\""))
        XCTAssertFalse(json.contains("pinnedLightId"))
    }

    func testDecode_neitherKeyPresent_leavesPinnedDeviceIdNil() throws {
        let json = """
            {
              "id": "DE000000-0000-0000-0000-000000000004",
              "displayName": "Hub",
              "kind": "demo"
            }
            """
        let hub = try JSONDecoder().decode(
            Hub.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertNil(hub.pinnedDeviceId)
    }
}
