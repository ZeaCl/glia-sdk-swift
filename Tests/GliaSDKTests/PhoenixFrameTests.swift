import XCTest
@testable import GliaSDK

final class PhoenixFrameTests: XCTestCase {
    func testParseValidPhoenixFrame() {
        let json = "[\"1\",\"2\",\"session:app:user\",\"phx_join\",{\"status\":\"ok\"}]"
        let frame = PhoenixFrame.parse(from: json)

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.joinRef, "1")
        XCTAssertEqual(frame?.ref, "2")
        XCTAssertEqual(frame?.topic, "session:app:user")
        XCTAssertEqual(frame?.event, "phx_join")
        XCTAssertEqual(frame?.payload["status"]?.stringValue, "ok")
    }

    func testParseNullRefs() {
        let json = "[null,\"3\",\"phoenix\",\"heartbeat\",{}]"
        let frame = PhoenixFrame.parse(from: json)

        XCTAssertNotNil(frame)
        XCTAssertNil(frame?.joinRef)
        XCTAssertEqual(frame?.ref, "3")
        XCTAssertEqual(frame?.topic, "phoenix")
        XCTAssertEqual(frame?.event, "heartbeat")
    }

    func testSerializeFrame() throws {
        let frame = PhoenixFrame(
            joinRef: "10",
            ref: "10",
            topic: "session:zea:usr1",
            event: "run",
            payload: ["message": "Hello"]
        )

        let serialized = try frame.serialize()
        let parsed = PhoenixFrame.parse(from: serialized)

        XCTAssertEqual(parsed?.joinRef, "10")
        XCTAssertEqual(parsed?.ref, "10")
        XCTAssertEqual(parsed?.topic, "session:zea:usr1")
        XCTAssertEqual(parsed?.event, "run")
        XCTAssertEqual(parsed?.payload["message"]?.stringValue, "Hello")
    }
}
