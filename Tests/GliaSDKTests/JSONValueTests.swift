import XCTest
@testable import GliaSDK

final class JSONValueTests: XCTestCase {
    func testLiteralsAndAccessors() {
        let str: JSONValue = "hello"
        XCTAssertEqual(str.stringValue, "hello")
        XCTAssertNil(str.doubleValue)

        let num: JSONValue = 42
        XCTAssertEqual(num.intValue, 42)
        XCTAssertEqual(num.doubleValue, 42.0)

        let boolVal: JSONValue = true
        XCTAssertEqual(boolVal.boolValue, true)

        let arrayVal: JSONValue = ["a", 1, false]
        XCTAssertEqual(arrayVal.arrayValue?.count, 3)
        XCTAssertEqual(arrayVal[0]?.stringValue, "a")
        XCTAssertEqual(arrayVal[1]?.intValue, 1)
        XCTAssertEqual(arrayVal[2]?.boolValue, false)

        let dictVal: JSONValue = [
            "name": "Glia",
            "active": true
        ]
        XCTAssertEqual(dictVal["name"]?.stringValue, "Glia")
        XCTAssertEqual(dictVal["active"]?.boolValue, true)

        let nullVal: JSONValue = nil
        XCTAssertTrue(nullVal.isNull)
    }

    func testCodableRoundtrip() throws {
        let json: JSONValue = [
            "string": "test",
            "integer": 100,
            "double": 3.1415,
            "boolean": false,
            "null": nil,
            "array": [1, 2, 3],
            "nested": [
                "inner": "value"
            ]
        ]

        let encoded = try JSONEncoder().encode(json)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

        XCTAssertEqual(decoded["string"]?.stringValue, "test")
        XCTAssertEqual(decoded["integer"]?.intValue, 100)
        XCTAssertEqual(decoded["boolean"]?.boolValue, false)
        XCTAssertEqual(decoded["null"]?.isNull, true)
        XCTAssertEqual(decoded["array"]?[1]?.intValue, 2)
        XCTAssertEqual(decoded["nested"]?["inner"]?.stringValue, "value")
    }

    func testFromAnyConversion() {
        let dict: [String: Any] = [
            "name": "Zea",
            "score": 99.5,
            "valid": true,
            "items": ["x", 10]
        ]

        let jsonVal = JSONValue.fromAny(dict)
        XCTAssertEqual(jsonVal["name"]?.stringValue, "Zea")
        XCTAssertEqual(jsonVal["score"]?.doubleValue, 99.5)
        XCTAssertEqual(jsonVal["valid"]?.boolValue, true)
        XCTAssertEqual(jsonVal["items"]?[0]?.stringValue, "x")
        XCTAssertEqual(jsonVal["items"]?[1]?.intValue, 10)
    }

    func testAnyCodableAndAnySendableCompatibilityAndSendability() async throws {
        // Validar AnyCodable
        let anyCodable = AnyCodable("swift 6 strict concurrency")
        XCTAssertEqual(anyCodable.value as? String, "swift 6 strict concurrency")
        XCTAssertEqual(anyCodable.toJSONValue, JSONValue.string("swift 6 strict concurrency"))

        let encoded = try JSONEncoder().encode(anyCodable)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        XCTAssertEqual(decoded, anyCodable)

        // Validar AnySendable
        let anySendable = AnySendable(12345)
        XCTAssertEqual(anySendable.value as? Int, 12345)

        // Validar envío a través de frontera Sendable
        let task = Task { () -> String in
            let sent: AnySendable = AnySendable("safe-across-tasks")
            return sent.value as? String ?? ""
        }
        let result = await task.value
        XCTAssertEqual(result, "safe-across-tasks")
    }
}
