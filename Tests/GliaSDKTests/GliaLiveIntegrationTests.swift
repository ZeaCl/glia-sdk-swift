import XCTest
@testable import GliaSDK

final class GliaLiveIntegrationTests: XCTestCase {
    func testLiveGatewayStreamingConnection() async throws {
        // Run only if GLIA_LIVE_TEST=1 is present in the environment
        guard ProcessInfo.processInfo.environment["GLIA_LIVE_TEST"] == "1" else {
            throw XCTSkip("GLIA_LIVE_TEST=1 is not configured. Skipping live E2E test against Phoenix Channels backend.")
        }

        let gatewayUrl = ProcessInfo.processInfo.environment["GLIA_LIVE_URL"] ?? "ws://localhost:4003"
        let appId = ProcessInfo.processInfo.environment["GLIA_LIVE_APP_ID"] ?? "test_app"
        let userId = ProcessInfo.processInfo.environment["GLIA_LIVE_USER_ID"] ?? "test_user_\(UUID().uuidString.prefix(8))"
        let token = ProcessInfo.processInfo.environment["GLIA_LIVE_TOKEN"]

        let options = GliaOptions(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            token: token,
            timeout: 10.0,
            autoReconnect: false
        )

        let client = GliaClient(options: options)

        // 1. Synchronous connection and phx_join
        try await client.connect()
        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected, "The client must confirm connection and successful phx_join handshake")

        // 2. Observe stream events
        let stream = await client.observeEvents()

        // 3. Send prompt
        try await client.send(prompt: "Hello from Swift SDK E2E test")

        let streamTask = Task { () -> (done: Bool, deltas: Int, error: String?) in
            var deltas = 0
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .messageDelta, .thinkingDelta:
                    deltas += 1
                case .done:
                    return (done: true, deltas: deltas, error: nil)
                case .error(let msg):
                    return (done: false, deltas: deltas, error: msg)
                default:
                    break
                }
            }
            return (done: false, deltas: deltas, error: Task.isCancelled ? "Timeout: no done event received within 15 seconds" : "Stream terminated prematurely")
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s timeout
            streamTask.cancel()
        }

        let result = await streamTask.value
        timeoutTask.cancel()

        if let error = result.error {
            XCTFail("Live stream failure: \(error)")
        }
        XCTAssertTrue(result.done, "Turn must complete with done event")
        XCTAssertGreaterThan(result.deltas, 0, "At least one response chunk/delta must be received")

        // 4. Clean voluntary disconnect
        await client.disconnect()
        let finalConnected = await client.isConnected
        XCTAssertFalse(finalConnected, "The client must reflect a clean disconnect")
    }
}
