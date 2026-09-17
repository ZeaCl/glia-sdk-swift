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
        XCTAssertTrue(options.autoReconnect)
        XCTAssertEqual(options.maxReconnectAttempts, 5)
    }

    func testDynamicToolEncoding() throws {
        let tool = GliaToolDefinition(
            name: "calculate_quote",
            description: "Calculates an estimate",
            parameters: [
                "type": "object",
                "properties": [
                    "amount": ["type": "number"]
                ]
            ],
            webhookUrl: "https://api.example.com/calculate"
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(GliaToolDefinition.self, from: data)

        XCTAssertEqual(decoded.name, "calculate_quote")
        XCTAssertEqual(decoded.webhookUrl, "https://api.example.com/calculate")
        XCTAssertEqual(decoded.parameters["type"]?.stringValue, "object")
    }

    func testURLNormalization() throws {
        // http -> ws
        let url1 = try GliaClient.normalizeGatewayURL("http://localhost:4003", token: nil)
        XCTAssertEqual(url1.scheme, "ws")
        XCTAssertEqual(url1.path, "/socket/websocket")
        XCTAssertTrue(url1.query?.contains("vsn=2.0.0") == true)

        // https -> wss with token
        let url2 = try GliaClient.normalizeGatewayURL("https://api.glia.ai/", token: "secret_123")
        XCTAssertEqual(url2.scheme, "wss")
        XCTAssertEqual(url2.path, "/socket/websocket")
        XCTAssertTrue(url2.query?.contains("vsn=2.0.0") == true)
        XCTAssertTrue(url2.query?.contains("token=secret_123") == true)

        // Existing wss without socket/websocket path
        let url3 = try GliaClient.normalizeGatewayURL("wss://api.example.com/custom")
        XCTAssertEqual(url3.path, "/custom/socket/websocket")
    }

    func testSuccessfulConnectWithJoinReply() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "ws://localhost:4003",
            appId: "app1",
            userId: "usr1",
            timeout: 2.0
        )

        let client = GliaClient(
            options: options,
            connectionFactory: { _, _ in mockConn }
        )

        // Simular respuesta del servidor phx_reply cuando llegue el join frame
        Task {
            // Esperar brevemente a que connect() envíe el join frame
            try await Task.sleep(nanoseconds: 50_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        try await client.connect()

        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected)
        XCTAssertTrue(mockConn.isResumed)
        XCTAssertFalse(mockConn.sentMessages.isEmpty)
    }

    func testConnectFailureWithJoinError() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "ws://localhost:4003",
            appId: "app1",
            userId: "usr1",
            timeout: 2.0
        )

        let client = GliaClient(
            options: options,
            connectionFactory: { _, _ in mockConn }
        )

        // Simular rechazo de join por token inválido
        Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"error\",\"response\":{\"reason\":\"unauthorized\"}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        do {
            try await client.connect()
            XCTFail("Debió fallar con GliaError.joinFailed")
        } catch let error as GliaError {
            XCTAssertEqual(error, GliaError.joinFailed(reason: "unauthorized"))
        }

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
    }

    func testVoluntaryDisconnectDoesNotEmitErrorAndFinishesStream() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "ws://localhost:4003",
            appId: "app1",
            userId: "usr1",
            timeout: 2.0
        )

        let client = GliaClient(
            options: options,
            connectionFactory: { _, _ in mockConn }
        )

        Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        try await client.connect()

        let stream = await client.observeEvents()
        var eventsReceived: [GliaStreamEvent] = []

        let consumerTask = Task {
            for await event in stream {
                eventsReceived.append(event)
            }
        }

        // Desconexión voluntaria
        await client.disconnect()

        // Esperar a que el loop del consumer finalice
        _ = await consumerTask.result

        // Debe terminar sin ningún .error emitido
        let hasError = eventsReceived.contains {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertFalse(hasError)
        XCTAssertTrue(mockConn.isCancelled)
    }

    func testStreamingEventsParsing() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "ws://localhost:4003",
            appId: "app1",
            userId: "usr1",
            timeout: 2.0
        )

        let client = GliaClient(
            options: options,
            connectionFactory: { _, _ in mockConn }
        )

        Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        try await client.connect()

        let stream = await client.observeEvents()

        // Inyectar eventos de streaming
        mockConn.pushIncoming(text: "[null,\"2\",\"session:app1:usr1\",\"thinking_delta\",{\"content\":\"Analizando...\"}]")
        mockConn.pushIncoming(text: "[null,\"3\",\"session:app1:usr1\",\"message_delta\",{\"content\":\"Hola \"}]")
        mockConn.pushIncoming(text: "[null,\"4\",\"session:app1:usr1\",\"message_delta\",{\"content\":\"mundo\"}]")
        mockConn.pushIncoming(text: "[null,\"5\",\"session:app1:usr1\",\"tool_call\",{\"name\":\"search\",\"args\":{\"query\":\"swift\"}}]")
        mockConn.pushIncoming(text: "[null,\"6\",\"session:app1:usr1\",\"tool_result\",{\"name\":\"search\",\"result\":\"ok\"}]")
        mockConn.pushIncoming(text: "[null,\"7\",\"session:app1:usr1\",\"done\",{\"full_message\":\"Hola mundo\"}]")

        var received: [GliaStreamEvent] = []
        for await event in stream {
            received.append(event)
            if case .done = event {
                break
            }
        }

        XCTAssertEqual(received.count, 6)
        XCTAssertEqual(received[0], .thinkingDelta("Analizando..."))
        XCTAssertEqual(received[1], .messageDelta("Hola "))
        XCTAssertEqual(received[2], .messageDelta("mundo"))
        XCTAssertEqual(received[3], .toolCall(name: "search", args: ["query": "swift"]))
        XCTAssertEqual(received[4], .toolResult(name: "search", result: "ok"))
        XCTAssertEqual(received[5], .done(fullMessage: "Hola mundo"))

        await client.disconnect()
    }
}
