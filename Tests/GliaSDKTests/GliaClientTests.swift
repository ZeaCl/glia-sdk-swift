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

        // Simulate server phx_reply response when join frame arrives
        Task {
            // Briefly wait for connect() to send join frame
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

        // Simulate join rejection due to invalid token
        Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"error\",\"response\":{\"reason\":\"unauthorized\"}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        do {
            try await client.connect()
            XCTFail("Should have failed with GliaError.joinFailed")
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
        let consumerTask = Task { () -> [GliaStreamEvent] in
            var received: [GliaStreamEvent] = []
            for await event in stream {
                received.append(event)
            }
            return received
        }

        // Voluntary disconnect
        await client.disconnect()

        // Wait for consumer loop to finish
        let eventsReceived = await consumerTask.value

        // Must terminate without any .error emitted
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

        // Inject streaming events
        mockConn.pushIncoming(text: "[null,\"2\",\"session:app1:usr1\",\"thinking_delta\",{\"content\":\"Analyzing...\"}]")
        mockConn.pushIncoming(text: "[null,\"3\",\"session:app1:usr1\",\"message_delta\",{\"content\":\"Hello \"}]")
        mockConn.pushIncoming(text: "[null,\"4\",\"session:app1:usr1\",\"message_delta\",{\"content\":\"world\"}]")
        mockConn.pushIncoming(text: "[null,\"5\",\"session:app1:usr1\",\"tool_call\",{\"name\":\"search\",\"args\":{\"query\":\"swift\"}}]")
        mockConn.pushIncoming(text: "[null,\"6\",\"session:app1:usr1\",\"tool_result\",{\"name\":\"search\",\"result\":\"ok\"}]")
        mockConn.pushIncoming(text: "[null,\"7\",\"session:app1:usr1\",\"done\",{\"full_message\":\"Hello world\"}]")

        var received: [GliaStreamEvent] = []
        for await event in stream {
            received.append(event)
            if case .done = event {
                break
            }
        }

        XCTAssertEqual(received.count, 6)
        XCTAssertEqual(received[0], .thinkingDelta("Analyzing..."))
        XCTAssertEqual(received[1], .messageDelta("Hello "))
        XCTAssertEqual(received[2], .messageDelta("world"))
        XCTAssertEqual(received[3], .toolCall(name: "search", args: ["query": "swift"]))
        XCTAssertEqual(received[4], .toolResult(name: "search", result: "ok"))
        XCTAssertEqual(received[5], .done(fullMessage: "Hello world"))

        await client.disconnect()
    }

    func testDoneEventWithTextPayloadContract() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "wss://api.zea.cl/glia/v1",
            appId: "app1",
            userId: "usr1"
        )
        let client = GliaClient(options: options, connectionFactory: { _, _ in mockConn })

        Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        try await client.connect()
        let stream = await client.observeEvents()

        // Backend emits: {:done, response} -> push(socket, "done", %{text: response})
        let doneFrame = "[null,\"2\",\"session:app1:usr1\",\"done\",{\"text\":\"Response from backend\"}]"
        mockConn.pushIncoming(text: doneFrame)

        for await event in stream {
            if case .done(let fullMessage) = event {
                XCTAssertEqual(fullMessage, "Response from backend")
                break
            }
        }

        await client.disconnect()
    }

    func testDoneEventWithFallbackToFullMessage() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "wss://api.zea.cl/glia/v1",
            appId: "app1",
            userId: "usr1"
        )
        let client = GliaClient(options: options, connectionFactory: { _, _ in mockConn })

        Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            let replyJson = "[\"1\",\"1\",\"session:app1:usr1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
            mockConn.pushIncoming(text: replyJson)
        }

        try await client.connect()
        let stream = await client.observeEvents()

        let doneFrame = "[null,\"2\",\"session:app1:usr1\",\"done\",{\"full_message\":\"Legacy response\"}]"
        mockConn.pushIncoming(text: doneFrame)

        for await event in stream {
            if case .done(let fullMessage) = event {
                XCTAssertEqual(fullMessage, "Legacy response")
                break
            }
        }

        await client.disconnect()
    }

    func testCanonicalGliaHostURLNormalization() throws {
        // wss://glia.zea.cl/socket -> wss://glia.zea.cl/socket/websocket (no double socket)
        let url1 = try GliaClient.normalizeGatewayURL("wss://glia.zea.cl/socket")
        XCTAssertEqual(url1.scheme, "wss")
        XCTAssertEqual(url1.host, "glia.zea.cl")
        XCTAssertEqual(url1.path, "/socket/websocket")

        // Trailing slash: wss://glia.zea.cl/socket/ -> wss://glia.zea.cl/socket/websocket
        let url2 = try GliaClient.normalizeGatewayURL("wss://glia.zea.cl/socket/")
        XCTAssertEqual(url2.path, "/socket/websocket")

        // Already full: wss://glia.zea.cl/socket/websocket -> unchanged
        let url3 = try GliaClient.normalizeGatewayURL("wss://glia.zea.cl/socket/websocket")
        XCTAssertEqual(url3.path, "/socket/websocket")
    }

    func testExplicitSessionIdOption() async throws {
        let options = GliaOptions(
            gatewayUrl: "https://api.zea.cl",
            appId: "food_app",
            userId: "usr_123",
            sessionId: "conv-uuid-456"
        )
        let client = GliaClient(options: options)

        let sessionId = client.sessionId
        let topic = await client.topic
        XCTAssertEqual(sessionId, "conv-uuid-456")
        XCTAssertEqual(topic, "session:conv-uuid-456")
    }

    func testHistoryJSONDecoding() throws {
        let json = """
        {
          "messages": [
            {
              "id": "c1356f62-73da-4700-9426-38d781b24e6a",
              "role": "user",
              "content": "¿Cuál es mi consumo hoy?",
              "sequence": 1,
              "inserted_at": "2026-10-23T18:00:00Z"
            },
            {
              "id": "e93108c9-59eb-4a24-9b26-5b4329a1b920",
              "role": "assistant",
              "content": "Hoy has consumido 1,850 kcal.",
              "sequence": 2,
              "inserted_at": "2026-10-23T18:00:05.123456Z"
            }
          ],
          "has_more": false,
          "session_id": "session-123"
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GliaHistoryResponse.self, from: data)

        XCTAssertEqual(response.sessionId, "session-123")
        XCTAssertFalse(response.hasMore)
        XCTAssertEqual(response.messages.count, 2)

        let m1 = response.messages[0]
        XCTAssertEqual(m1.id, "c1356f62-73da-4700-9426-38d781b24e6a")
        XCTAssertEqual(m1.role, .user)
        XCTAssertEqual(m1.content, "¿Cuál es mi consumo hoy?")
        XCTAssertEqual(m1.sequence, 1)
        XCTAssertNotNil(m1.insertedAt)

        let m2 = response.messages[1]
        XCTAssertEqual(m2.id, "e93108c9-59eb-4a24-9b26-5b4329a1b920")
        XCTAssertEqual(m2.role, .assistant)
        XCTAssertEqual(m2.content, "Hoy has consumido 1,850 kcal.")
        XCTAssertEqual(m2.sequence, 2)
        XCTAssertNotNil(m2.insertedAt)
    }

    func testFetchHistoryViaWebSocket() async throws {
        let mockConn = MockWebSocketConnection()
        let options = GliaOptions(
            gatewayUrl: "wss://glia.zea.cl/socket",
            appId: "app1",
            userId: "usr1",
            sessionId: "test-session"
        )
        let client = GliaClient(options: options, connectionFactory: { _, _ in mockConn })

        // 1. Simulate join reply
        Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            let joinReply = "[\"1\",\"1\",\"session:test-session\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
            mockConn.pushIncoming(text: joinReply)
        }

        try await client.connect()

        // 2. Simulate history reply
        Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            let historyReply = """
            ["1","2","session:test-session","phx_reply",{"status":"ok","response":{"messages":[{"id":"m1","role":"user","content":"Hi!","sequence":1,"inserted_at":"2026-10-23T18:00:00Z"}],"has_more":false}}]
            """
            mockConn.pushIncoming(text: historyReply)
        }

        let history = try await client.fetchHistory(limit: 20, beforeSequence: nil)
        XCTAssertFalse(history.hasMore)
        XCTAssertEqual(history.messages.count, 1)
        XCTAssertEqual(history.messages.first?.content, "Hi!")
        XCTAssertEqual(history.messages.first?.sequence, 1)

        // Verify sent message format
        let sentHistoryMsg = mockConn.sentMessages.compactMap { msg -> String? in
            if case .string(let s) = msg, s.contains("get_history") {
                return s
            }
            return nil
        }.first

        XCTAssertNotNil(sentHistoryMsg)
        XCTAssertTrue(sentHistoryMsg?.contains("\"get_history\"") == true)
        XCTAssertTrue(sentHistoryMsg?.contains("\"session:test-session\"") == true)

        await client.disconnect()
    }

    func testBuildHistoryRequestURL() throws {
        let options = GliaOptions(
            gatewayUrl: "wss://glia.zea.cl/socket",
            appId: "app1",
            userId: "usr1",
            sessionId: "session-abc"
        )
        let client = GliaClient(options: options)

        let url = try client.buildHistoryRequestURL(limit: 15, beforeSequence: 42)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "glia.zea.cl")
        XCTAssertEqual(url.path, "/api/conversations/session-abc/messages")
        XCTAssertTrue(url.query?.contains("limit=15") == true)
        XCTAssertTrue(url.query?.contains("before_sequence=42") == true)
    }

    func testSessionIdPathTraversalSanitizationInREST() throws {
        let options = GliaOptions(
            gatewayUrl: "https://api.zea.cl",
            appId: "app",
            userId: "user",
            sessionId: "app/tenant:admin/../secret"
        )
        let client = GliaClient(options: options)

        let url = try client.buildHistoryRequestURL(limit: 20, beforeSequence: nil)
        XCTAssertEqual(url.path, "/api/conversations/app%2Ftenant:admin%2F..%2Fsecret/messages")
        XCTAssertFalse(url.path.contains("/../"))
    }

    func testMessageRoleResilienceToUnknownRoles() throws {
        let json = """
        {
          "id": "m-tool",
          "role": "tool",
          "content": "Result from tool execution"
        }
        """
        let data = json.data(using: .utf8)!
        let msg = try JSONDecoder().decode(GliaMessage.self, from: data)

        XCTAssertEqual(msg.role, .unknown("tool"))
        XCTAssertEqual(msg.role.rawValue, "tool")

        let encoded = try JSONEncoder().encode(msg)
        let roundtrip = try JSONDecoder().decode(GliaMessage.self, from: encoded)
        XCTAssertEqual(roundtrip.role, .unknown("tool"))
    }
}
