import XCTest
@testable import GliaSDK

final class TelemetryTests: XCTestCase {

    struct MockError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 1. Zero PII Sanitization & String Truncation
    func testSanitizationZeroPIIAndPayloadTruncation() {
        // Test truncation > 1024 chars
        let longString = String(repeating: "a", count: 2000)
        let truncated = TelemetrySanitizer.truncate(longString)
        XCTAssertEqual(truncated.count, 1024)
        XCTAssertEqual(truncated, String(repeating: "a", count: 1024))

        // Test PII pattern masking
        let emailSample = "Contact developer@zea.cl for support"
        let sanitizedEmail = TelemetrySanitizer.sanitizeString(emailSample)
        XCTAssertEqual(sanitizedEmail, "Contact [REDACTED_EMAIL] for support")

        let jwtSample = "eyJhGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.sflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let sanitizedJWT = TelemetrySanitizer.sanitizeString("Token is \(jwtSample)")
        XCTAssertEqual(sanitizedJWT, "Token is [REDACTED_JWT]")

        let bearerSample = "Bearer secret_api_token_value_here"
        let sanitizedBearer = TelemetrySanitizer.sanitizeString(bearerSample)
        XCTAssertEqual(sanitizedBearer, "Bearer [REDACTED]")

        // Test metadata key redaction
        let metadata: [String: JSONValue] = [
            "user_password": .string("super_secret_123"),
            "auth_token": .string("token_xyz"),
            "credit_card": .string("4532-xxxx-xxxx-1234"),
            "flow_step": .string("checkout_initiated"),
            "safe_number": .number(42)
        ]
        let sanitizedMeta = TelemetrySanitizer.sanitizeMetadata(metadata)!
        XCTAssertEqual(sanitizedMeta["user_password"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(sanitizedMeta["auth_token"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(sanitizedMeta["credit_card"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(sanitizedMeta["flow_step"]?.stringValue, "checkout_initiated")
        XCTAssertEqual(sanitizedMeta["safe_number"]?.doubleValue, 42.0)
    }

    // MARK: - 2. Offline FIFO Buffer (Capacity 50, drop oldest)
    func testOfflineFIFOBufferingAndMaxCapacity50() async {
        let manager = TelemetryManager(maxBufferSize: 50)

        // Enqueue 60 items
        for i in 1...60 {
            let event = TelemetryEvent(
                seq: i,
                type: .event,
                name: "event_\(i)",
                message: "Payload \(i)"
            )
            await manager.enqueue(event)
        }

        let count = await manager.bufferedCount
        XCTAssertEqual(count, 50, "Buffer capacity must not exceed 50")

        let flushed = await manager.flush()
        XCTAssertEqual(flushed.count, 50)

        // Oldest 10 (1...10) must have been dropped, buffer should contain 11...60
        XCTAssertEqual(flushed.first?.seq, 11)
        XCTAssertEqual(flushed.first?.name, "event_11")
        XCTAssertEqual(flushed.last?.seq, 60)
        XCTAssertEqual(flushed.last?.name, "event_60")

        let countAfterFlush = await manager.bufferedCount
        XCTAssertEqual(countAfterFlush, 0, "Buffer must be empty after flush")
    }

    // MARK: - 3. Circuit Breaker (60s Window repeated error suppression)
    func testCircuitBreakerSuppression60Seconds() async {
        let manager = TelemetryManager(circuitBreakerWindow: 60.0)
        let baseDate = Date()

        // 1st occurrence: Should NOT be suppressed
        let suppress1 = await manager.shouldSuppressError(flow: "food_scan", code: "DTO_PARSE_ERR", now: baseDate)
        XCTAssertFalse(suppress1, "First error must not be suppressed")

        // 2nd through 40th occurrences within 10s: Should ALL be suppressed
        for offset in 1...40 {
            let date = baseDate.addingTimeInterval(Double(offset) * 0.25)
            let suppressed = await manager.shouldSuppressError(flow: "food_scan", code: "DTO_PARSE_ERR", now: date)
            XCTAssertTrue(suppressed, "Repeated error within 60s window must be suppressed")
        }

        // Different error code on same flow: Should NOT be suppressed
        let differentCode = await manager.shouldSuppressError(flow: "food_scan", code: "NETWORK_TIMEOUT", now: baseDate.addingTimeInterval(5.0))
        XCTAssertFalse(differentCode, "Different error code must not be suppressed")

        // Different flow on same code: Should NOT be suppressed
        let differentFlow = await manager.shouldSuppressError(flow: "auth_scan", code: "DTO_PARSE_ERR", now: baseDate.addingTimeInterval(5.0))
        XCTAssertFalse(differentFlow, "Different flow must not be suppressed")

        // Same error after 61 seconds: Should NOT be suppressed (circuit breaker resets)
        let futureDate = baseDate.addingTimeInterval(61.0)
        let afterWindow = await manager.shouldSuppressError(flow: "food_scan", code: "DTO_PARSE_ERR", now: futureDate)
        XCTAssertFalse(afterWindow, "Error after 60s window must be allowed")
    }

    // MARK: - 4. Immediate Transmission over WebSocket when Connected
    func testTrackErrorImmediateSendWhenConnected() async throws {
        let mockConnection = MockWebSocketConnection()
        let client = GliaClient(
            options: GliaOptions(
                gatewayUrl: "wss://api.zea.cl",
                appId: "food_app",
                userId: "user_123",
                timeout: 2.0
            ),
            connectionFactory: { _, _ in mockConnection }
        )

        // Connect client and simulate Phoenix join reply
        let connectTask = Task {
            try await client.connect()
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        // Mock phx_join reply (Phoenix v2 array format)
        let joinReply = "[\"1\",\"1\",\"session:food_app:user_123\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
        mockConnection.pushIncoming(text: joinReply)

        try await connectTask.value
        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected)

        // Send trackError
        let error = MockError(message: "JSON corrupted in payload")
        await client.trackError(
            flow: "food_scan",
            error: error,
            endpoint: "/api/analyze/food",
            code: "DECODING_ERR"
        )

        // Verify WebSocket received the track_event frame
        let sent = mockConnection.sentMessages
        let lastMessage = sent.last

        guard case .string(let text) = lastMessage else {
            XCTFail("Expected string message sent over websocket")
            return
        }

        guard let frame = PhoenixFrame.parse(from: text) else {
            XCTFail("Expected valid PhoenixFrame")
            return
        }

        XCTAssertEqual(frame.event, "track_event")
        XCTAssertEqual(frame.topic, "session:food_app:user_123")
        XCTAssertEqual(frame.payload["flow"]?.stringValue, "food_scan")
        XCTAssertEqual(frame.payload["endpoint"]?.stringValue, "/api/analyze/food")
        XCTAssertEqual(frame.payload["code"]?.stringValue, "DECODING_ERR")
        XCTAssertEqual(frame.payload["message"]?.stringValue, "JSON corrupted in payload")
        XCTAssertEqual(frame.payload["type"]?.stringValue, "error")
        XCTAssertEqual(frame.payload["seq"]?.intValue, 1)

        await client.disconnect()
    }

    // MARK: - 5. Offline Buffer Flushing on Reconnect
    func testOfflineBufferFlushingOnReconnect() async throws {
        let mockConnection = MockWebSocketConnection()
        let manager = TelemetryManager(maxBufferSize: 50)
        let client = GliaClient(
            options: GliaOptions(
                gatewayUrl: "wss://api.zea.cl",
                appId: "food_app",
                userId: "user_offline",
                timeout: 2.0
            ),
            telemetryManager: manager,
            connectionFactory: { _, _ in mockConnection }
        )

        // Client is initially disconnected
        let isConnectedInitial = await client.isConnected
        XCTAssertFalse(isConnectedInitial)

        // Track events while offline
        await client.trackEvent(name: "offline_step_1", flow: "checkout")
        await client.trackEvent(name: "offline_step_2", flow: "checkout")
        await client.trackError(flow: "checkout", error: MockError(message: "Offline network failure"))

        let countWhileOffline = await manager.bufferedCount
        XCTAssertEqual(countWhileOffline, 3, "Events must be buffered in FIFO queue when offline")
        XCTAssertEqual(mockConnection.sentMessages.count, 0, "No socket messages should be sent while offline")

        // Now connect client
        let connectTask = Task {
            try await client.connect()
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        // Provide phx_reply to complete join (Phoenix v2 array format)
        let joinReply = "[\"1\",\"1\",\"session:food_app:user_offline\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"
        mockConnection.pushIncoming(text: joinReply)

        try await connectTask.value

        // Allow flush tasks to process
        try await Task.sleep(nanoseconds: 30_000_000)

        // Verify buffer is empty
        let countAfterReconnect = await manager.bufferedCount
        XCTAssertEqual(countAfterReconnect, 0, "Buffer should be flushed completely on connect")

        // Verify all 3 events were transmitted over WebSocket
        let sentFrames = mockConnection.sentMessages.compactMap { msg -> PhoenixFrame? in
            if case .string(let text) = msg {
                return PhoenixFrame.parse(from: text)
            }
            return nil
        }.filter { $0.event == "track_event" }

        XCTAssertEqual(sentFrames.count, 3)
        XCTAssertEqual(sentFrames[0].payload["name"]?.stringValue, "offline_step_1")
        XCTAssertEqual(sentFrames[1].payload["name"]?.stringValue, "offline_step_2")
        XCTAssertEqual(sentFrames[2].payload["type"]?.stringValue, "error")

        await client.disconnect()
    }

    // MARK: - 6. High Concurrency Stress Test (1,000 Tasks)
    func testHighConcurrencyStress1000Tasks() async throws {
        let manager = TelemetryManager(maxBufferSize: 50)
        let client = GliaClient(
            gatewayUrl: "wss://api.zea.cl",
            appId: "stress_app",
            userId: "stress_user",
            telemetryManager: manager
        )

        // Execute 1,000 concurrent calls from separate Tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 1...1000 {
                group.addTask {
                    if i % 2 == 0 {
                        await client.trackError(
                            flow: "stress_flow_\(i % 10)",
                            error: MockError(message: "Error \(i)"),
                            code: "ERR_\(i)"
                        )
                    } else {
                        await client.trackEvent(
                            name: "event_\(i)",
                            flow: "stress_flow_\(i % 10)"
                        )
                    }
                }
            }
        }

        // Verify manager state is coherent
        let bufferedCount = await manager.bufferedCount
        XCTAssertLessThanOrEqual(bufferedCount, 50, "Buffer must remain bounded under intense load")
        let flushed = await manager.flush()
        XCTAssertLessThanOrEqual(flushed.count, 50)
        XCTAssertGreaterThan(flushed.count, 0)
    }

    // MARK: - 7. Memory Footprint Test (50 events < 250 KB)
    func testMemoryUsageBuffer50EventsUnder250KB() throws {
        var events: [TelemetryEvent] = []
        for i in 1...50 {
            let metadata: [String: JSONValue] = [
                "device_model": .string("iPhone15,2"),
                "system_version": .string("17.4"),
                "sample_info": .string(String(repeating: "x", count: 200))
            ]
            let event = TelemetryEvent(
                seq: i,
                type: .error,
                name: "error",
                flow: "scan_flow",
                endpoint: "/api/v1/scan",
                message: "Error message details \(i)",
                code: "PARSE_ERR",
                errorType: "DecodingError",
                metadata: metadata
            )
            events.append(event)
        }

        let data = try JSONEncoder().encode(events)
        let kilobytes = Double(data.count) / 1024.0
        XCTAssertLessThan(kilobytes, 250.0, "50 items payload size in memory must be well under 250 KB")
    }

    // MARK: - 8. GliaClient.shared Singleton & Configure
    func testGliaClientSharedConfiguration() {
        let initialShared = GliaClient.shared
        XCTAssertNotNil(initialShared)

        let customClient = GliaClient(gatewayUrl: "wss://custom.zea.cl", appId: "custom_app", userId: "custom_user")
        GliaClient.configure(shared: customClient)
        XCTAssertEqual(GliaClient.shared.options.appId, "custom_app")
        XCTAssertEqual(GliaClient.shared.options.userId, "custom_user")
    }
}
