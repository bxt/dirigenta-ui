import XCTest

@testable import dirigenta_ui

@MainActor
final class WebSocketFrameDecodeTests: XCTestCase {

    // MARK: Valid string frames

    func testValidStringFrame_decodesEvent() {
        let msg = URLSessionWebSocketTask.Message.string(#"{"type":"deviceStateChanged"}"#)
        let event = decodeDirigeraWebSocketFrame(msg)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.type, "deviceStateChanged")
    }

    func testValidStringFrame_withData_decodesEvent() {
        let json = """
            {"type":"deviceStateChanged","data":{"id":"light-1","attributes":{"isOn":true}}}
            """
        let event = decodeDirigeraWebSocketFrame(.string(json))
        XCTAssertEqual(event?.data?.id, "light-1")
        XCTAssertEqual(event?.data?.attributes?.isOn, true)
    }

    func testUnknownEventType_decodesWithoutError() {
        // Unknown type values should decode fine — type is just a String.
        let event = decodeDirigeraWebSocketFrame(.string(#"{"type":"someNewEventType"}"#))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.type, "someNewEventType")
    }

    func testPingFrame_decodesCorrectly() {
        let event = decodeDirigeraWebSocketFrame(.string(#"{"type":"ping"}"#))
        XCTAssertNotNil(event)
    }

    // MARK: Malformed / unexpected frames

    func testMalformedJSON_returnsNil_doesNotCrash() {
        let event = decodeDirigeraWebSocketFrame(.string("not json at all"))
        XCTAssertNil(event)
    }

    func testEmptyString_returnsNil() {
        let event = decodeDirigeraWebSocketFrame(.string(""))
        XCTAssertNil(event)
    }

    func testMissingRequiredField_returnsNil() {
        // DirigeraEvent requires "type"; without it decoding should fail.
        let event = decodeDirigeraWebSocketFrame(.string(#"{"data":{"id":"x"}}"#))
        XCTAssertNil(event)
    }

    func testPartiallyValidJSON_returnsNil() {
        let event = decodeDirigeraWebSocketFrame(.string(#"{"type":"#))
        XCTAssertNil(event)
    }

    // MARK: Binary frames

    func testBinaryFrame_returnsNil_doesNotCrash() {
        let data = Data([0x00, 0xFF, 0x42])
        let event = decodeDirigeraWebSocketFrame(.data(data))
        XCTAssertNil(event)
    }

    func testBinaryFrameWithValidJSON_stillReturnsNil() {
        // Even if binary happens to contain valid JSON, we skip it —
        // the hub protocol sends text frames only.
        let data = #"{"type":"deviceStateChanged"}"#.data(using: .utf8)!
        let event = decodeDirigeraWebSocketFrame(.data(data))
        XCTAssertNil(event)
    }

    func testEmptyBinaryFrame_returnsNil() {
        let event = decodeDirigeraWebSocketFrame(.data(Data()))
        XCTAssertNil(event)
    }
}
