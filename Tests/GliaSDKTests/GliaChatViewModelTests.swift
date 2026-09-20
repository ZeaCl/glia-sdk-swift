#if canImport(SwiftUI) && canImport(Combine)
import XCTest
@testable import GliaSDK
@testable import GliaUI

final class MockGliaClient: GliaClientProtocol, @unchecked Sendable {
    var isConnected: Bool = false
    var shouldFailConnect: Bool = false
    var sentPrompts: [String] = []

    private var eventContinuation: AsyncStream<GliaStreamEvent>.Continuation?

    func connect() async throws {
        if shouldFailConnect {
            throw GliaError.joinFailed(reason: "unauthorized")
        }
        isConnected = true
    }

    func disconnect() async {
        isConnected = false
        eventContinuation?.finish()
    }

    func send(prompt: String, systemPrompt: String?, tools: [GliaToolDefinition]) async throws {
        sentPrompts.append(prompt)
    }

    func observeEvents() async -> AsyncStream<GliaStreamEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    func emit(_ event: GliaStreamEvent) {
        eventContinuation?.yield(event)
    }
}

@MainActor
final class GliaChatViewModelTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms poll
        }
        XCTFail("Timeout waiting for condition after \(timeout) seconds")
    }

    func testConnectSuccessAndStreamAccumulation() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await waitUntil { viewModel.isConnected }
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertNil(viewModel.errorMessage)

        // Send user message
        viewModel.send(prompt: "Hello")
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.role, .user)
        XCTAssertEqual(viewModel.messages.first?.content, "Hello")
        XCTAssertTrue(viewModel.isStreaming)

        // Simulate streaming deltas
        mockClient.emit(.thinkingDelta("Thinking..."))
        try await waitUntil { viewModel.currentThinking == "Thinking..." }
        XCTAssertEqual(viewModel.currentThinking, "Thinking...")

        mockClient.emit(.messageDelta("Complete "))
        mockClient.emit(.messageDelta("response."))
        try await waitUntil { viewModel.currentText == "Complete response." }
        XCTAssertEqual(viewModel.currentText, "Complete response.")

        mockClient.emit(.toolCall(name: "search_db", args: [:]))
        try await waitUntil { viewModel.currentTool == "search_db" }
        XCTAssertEqual(viewModel.currentTool, "search_db")

        mockClient.emit(.toolResult(name: "search_db", result: "ok"))
        try await waitUntil { viewModel.currentTool == nil }
        XCTAssertNil(viewModel.currentTool)

        mockClient.emit(.done(fullMessage: "Complete response."))
        try await waitUntil { !viewModel.isStreaming && viewModel.messages.count == 2 }

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Complete response.")
        XCTAssertEqual(viewModel.messages[1].thinking, "Thinking...")
    }

    func testStreamErrorHandling() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await waitUntil { viewModel.isConnected }

        viewModel.send(prompt: "Question")
        XCTAssertTrue(viewModel.isStreaming)

        mockClient.emit(.error("Temporary API failure"))
        try await waitUntil { !viewModel.isStreaming && viewModel.errorMessage == "Temporary API failure" }

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.errorMessage, "Temporary API failure")
    }

    func testToolNamePreservedInAssistantMessageAfterToolResult() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await waitUntil { viewModel.isConnected }

        viewModel.send(prompt: "Check balance")
        XCTAssertTrue(viewModel.isStreaming)

        // Simulate tool execution: toolCall -> toolResult -> done
        mockClient.emit(.toolCall(name: "check_balance", args: [:]))
        try await waitUntil { viewModel.currentTool == "check_balance" }
        XCTAssertEqual(viewModel.currentTool, "check_balance")

        mockClient.emit(.toolResult(name: "check_balance", result: .string("OK")))
        try await waitUntil { viewModel.currentTool == nil }
        XCTAssertNil(viewModel.currentTool)

        mockClient.emit(.done(fullMessage: "Your available balance is $150.00"))
        try await waitUntil { !viewModel.isStreaming && viewModel.messages.count == 2 }

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.count, 2)

        let assistantMessage = viewModel.messages.last
        XCTAssertEqual(assistantMessage?.role, .assistant)
        XCTAssertEqual(assistantMessage?.content, "Your available balance is $150.00")
        // Verify that toolName was preserved despite toolResult lifecycle
        XCTAssertEqual(assistantMessage?.toolName, "check_balance")
    }

    func testSendIgnoredWhileStreaming() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await waitUntil { viewModel.isConnected }

        viewModel.send(prompt: "First message")
        XCTAssertTrue(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.count, 1)

        try await waitUntil { mockClient.sentPrompts.count == 1 }
        XCTAssertEqual(mockClient.sentPrompts, ["First message"])

        // Attempt to send while stream is still running
        viewModel.send(prompt: "Second concurrent message")
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(mockClient.sentPrompts, ["First message"]) // Must not be sent

        // Finish stream
        mockClient.emit(.done(fullMessage: "Response"))
        try await waitUntil { !viewModel.isStreaming }
        XCTAssertFalse(viewModel.isStreaming)

        // Now it should allow sending
        viewModel.send(prompt: "Third post-streaming message")
        try await waitUntil { mockClient.sentPrompts.count == 2 }
        XCTAssertEqual(viewModel.messages.count, 3) // user1, assistant1, user2
        XCTAssertEqual(mockClient.sentPrompts, ["First message", "Third post-streaming message"])
    }

    func testInitialMessagesAndOnMessagesUpdated() async throws {
        let initial = [
            GliaChatMessage(role: .user, content: "Previous history 1"),
            GliaChatMessage(role: .assistant, content: "Previous history 2")
        ]

        var capturedUpdates: [[GliaChatMessage]] = []
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(
            client: mockClient,
            initialMessages: initial,
            onMessagesUpdated: { updated in
                capturedUpdates.append(updated)
            }
        )

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "Previous history 1")
        XCTAssertEqual(viewModel.messages[1].content, "Previous history 2")

        viewModel.connect()
        try await waitUntil { viewModel.isConnected }

        viewModel.send(prompt: "Message 3")
        XCTAssertEqual(viewModel.messages.count, 3)
        XCTAssertEqual(capturedUpdates.count, 1)
        XCTAssertEqual(capturedUpdates.last?.count, 3)

        mockClient.emit(.done(fullMessage: "Response 3"))
        try await waitUntil { !viewModel.isStreaming && viewModel.messages.count == 4 }

        XCTAssertEqual(capturedUpdates.count, 2)
        XCTAssertEqual(capturedUpdates.last?.count, 4)
        XCTAssertEqual(capturedUpdates.last?.last?.content, "Response 3")
    }

    func testGliaChatMessageCodableRoundtrip() throws {
        let original = [
            GliaChatMessage(role: .user, content: "User question"),
            GliaChatMessage(role: .assistant, content: "Bot response", thinking: "Thinking...", toolName: "search")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode([GliaChatMessage].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].role, .user)
        XCTAssertEqual(decoded[0].content, "User question")
        XCTAssertEqual(decoded[1].role, .assistant)
        XCTAssertEqual(decoded[1].content, "Bot response")
        XCTAssertEqual(decoded[1].thinking, "Thinking...")
        XCTAssertEqual(decoded[1].toolName, "search")
    }
}
#endif
