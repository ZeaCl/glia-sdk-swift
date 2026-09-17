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
    func testConnectSuccessAndStreamAccumulation() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()

        // Esperar a que connect() y observeEvents() se establezcan
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertNil(viewModel.errorMessage)

        // Enviar mensaje del usuario
        viewModel.send(prompt: "Hola")
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.role, .user)
        XCTAssertEqual(viewModel.messages.first?.content, "Hola")
        XCTAssertTrue(viewModel.isStreaming)

        // Simular deltas de streaming
        mockClient.emit(.thinkingDelta("Pensando..."))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.currentThinking, "Pensando...")

        mockClient.emit(.messageDelta("Respuesta "))
        mockClient.emit(.messageDelta("completa."))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.currentText, "Respuesta completa.")

        mockClient.emit(.toolCall(name: "search_db", args: [:]))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.currentTool, "search_db")

        mockClient.emit(.toolResult(name: "search_db", result: "ok"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(viewModel.currentTool)

        mockClient.emit(.done(fullMessage: "Respuesta completa."))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Respuesta completa.")
        XCTAssertEqual(viewModel.messages[1].thinking, "Pensando...")
    }

    func testStreamErrorHandling() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        viewModel.send(prompt: "Pregunta")
        XCTAssertTrue(viewModel.isStreaming)

        mockClient.emit(.error("Fallo temporal de API"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.errorMessage, "Fallo temporal de API")
    }

    func testToolNamePreservedInAssistantMessageAfterToolResult() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        viewModel.send(prompt: "Consulta mi saldo")
        XCTAssertTrue(viewModel.isStreaming)

        // Simular ejecución de tool: toolCall -> toolResult -> done
        mockClient.emit(.toolCall(name: "check_balance", args: [:]))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.currentTool, "check_balance")

        mockClient.emit(.toolResult(name: "check_balance", result: .string("OK")))
        try await Task.sleep(nanoseconds: 20_000_000)
        // currentTool se limpió en toolResult
        XCTAssertNil(viewModel.currentTool)

        mockClient.emit(.done(fullMessage: "Tu saldo disponible es $150.000 CLP"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.count, 2)

        let assistantMessage = viewModel.messages.last
        XCTAssertEqual(assistantMessage?.role, .assistant)
        XCTAssertEqual(assistantMessage?.content, "Tu saldo disponible es $150.000 CLP")
        // Verificar que toolName se preservó a pesar del ciclo de toolResult
        XCTAssertEqual(assistantMessage?.toolName, "check_balance")
    }

    func testSendIgnoredWhileStreaming() async throws {
        let mockClient = MockGliaClient()
        let viewModel = GliaChatViewModel(client: mockClient)

        viewModel.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        viewModel.send(prompt: "Primer mensaje")
        XCTAssertTrue(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.count, 1)

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(mockClient.sentPrompts, ["Primer mensaje"])

        // Intentar enviar mientras el stream sigue en curso
        viewModel.send(prompt: "Segundo mensaje concurrente")
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(mockClient.sentPrompts, ["Primer mensaje"]) // No debe enviarse

        // Finalizar stream
        mockClient.emit(.done(fullMessage: "Respuesta"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(viewModel.isStreaming)

        // Ahora sí debe permitir enviar
        viewModel.send(prompt: "Tercer mensaje post streaming")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.messages.count, 3) // user1, assistant1, user2
        XCTAssertEqual(mockClient.sentPrompts, ["Primer mensaje", "Tercer mensaje post streaming"])
    }
}
#endif
