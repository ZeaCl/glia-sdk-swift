import XCTest
@testable import GliaSDK

final class GliaClientTests: XCTestCase {
    func testGliaClientInitialization() async throws {
        let client = GliaClient(
            gatewayUrl: "ws://localhost:4003",
            appId: "test-app",
            userId: "user-123",
            token: "jwt-token",
            systemPrompt: "You are a helpful assistant."
        )

        let topic = await client.topic
        XCTAssertEqual(topic, "session:test-app:user-123")

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
    }

    func testGliaOptionsDefaults() {
        let options = GliaOptions(
            gatewayUrl: "wss://glia.example.com",
            appId: "finance-agent",
            userId: "usr_456"
        )

        XCTAssertEqual(options.gatewayUrl, "wss://glia.example.com")
        XCTAssertEqual(options.appId, "finance-agent")
        XCTAssertEqual(options.userId, "usr_456")
        XCTAssertNil(options.token)
        XCTAssertNil(options.systemPrompt)
        XCTAssertEqual(options.timeout, 60.0)
    }

    func testDynamicToolEncoding() throws {
        let tool = GliaToolDefinition(
            name: "calculate_quote",
            description: "Calculates an estimate",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "amount": AnyCodable(["type": "number"])
                ])
            ],
            webhookUrl: "https://api.example.com/calculate"
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(GliaToolDefinition.self, from: data)

        XCTAssertEqual(decoded.name, "calculate_quote")
        XCTAssertEqual(decoded.webhookUrl, "https://api.example.com/calculate")
    }
}
