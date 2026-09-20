#if canImport(SwiftUI) && canImport(Combine)
import Foundation
import SwiftUI
import GliaSDK

public enum GliaMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct GliaChatMessage: Identifiable, Sendable, Codable {
    public let id: UUID
    public let role: GliaMessageRole
    public let content: String
    public let thinking: String?
    public let toolName: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: GliaMessageRole,
        content: String,
        thinking: String? = nil,
        toolName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolName = toolName
        self.timestamp = timestamp
    }
}

@MainActor
public final class GliaChatViewModel: ObservableObject {
    @Published public private(set) var messages: [GliaChatMessage] = []
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var currentThinking: String = ""
    @Published public private(set) var currentText: String = ""
    @Published public private(set) var currentTool: String? = nil
    @Published public private(set) var errorMessage: String? = nil

    public var onMessagesUpdated: (([GliaChatMessage]) -> Void)?

    private var lastExecutedTool: String? = nil
    private let client: GliaClientProtocol
    private var eventsTask: Task<Void, Never>?

    public init(
        client: GliaClientProtocol,
        initialMessages: [GliaChatMessage] = [],
        onMessagesUpdated: (([GliaChatMessage]) -> Void)? = nil
    ) {
        self.client = client
        self.messages = initialMessages
        self.onMessagesUpdated = onMessagesUpdated
    }

    public func loadMessages(_ newMessages: [GliaChatMessage]) {
        self.messages = newMessages
        self.onMessagesUpdated?(newMessages)
    }

    public func clearMessages() {
        self.messages = []
        self.onMessagesUpdated?([])
    }

    public func connect() {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try await self.client.connect()
                self.isConnected = true
                self.errorMessage = nil

                let stream = await self.client.observeEvents()
                for await event in stream {
                    self.handleEvent(event)
                }
            } catch {
                self.isConnected = false
                self.errorMessage = "Error connecting to Glia: \(error.localizedDescription)"
            }
        }
    }

    public func disconnect() {
        eventsTask?.cancel()
        eventsTask = nil
        Task { [weak self] in
            await self?.client.disconnect()
            self?.isConnected = false
        }
    }

    public func send(prompt: String, systemPrompt: String? = nil, tools: [GliaToolDefinition] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        let userMsg = GliaChatMessage(role: .user, content: trimmed)
        messages.append(userMsg)
        onMessagesUpdated?(messages)

        isStreaming = true
        currentThinking = ""
        currentText = ""
        currentTool = nil
        lastExecutedTool = nil
        errorMessage = nil

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.client.send(prompt: trimmed, systemPrompt: systemPrompt, tools: tools)
            } catch {
                self.isStreaming = false
                self.errorMessage = "Error sending message: \(error.localizedDescription)"
            }
        }
    }

    private func handleEvent(_ event: GliaStreamEvent) {
        switch event {
        case .status(let status):
            if status == "idle" && !isStreaming {
                currentTool = nil
            }

        case .thinkingDelta(let delta):
            currentThinking += delta

        case .messageDelta(let delta):
            currentText += delta

        case .toolCall(let name, _):
            currentTool = name
            lastExecutedTool = name

        case .toolResult(let name, _):
            if currentTool == name {
                currentTool = nil
            }

        case .done(let fullMessage):
            let textToSave = (fullMessage?.isEmpty == false) ? fullMessage! : currentText
            if !textToSave.isEmpty {
                let assistantMsg = GliaChatMessage(
                    role: .assistant,
                    content: textToSave,
                    thinking: currentThinking.isEmpty ? nil : currentThinking,
                    toolName: lastExecutedTool ?? currentTool
                )
                messages.append(assistantMsg)
                onMessagesUpdated?(messages)
            }
            isStreaming = false
            currentThinking = ""
            currentText = ""
            currentTool = nil
            lastExecutedTool = nil

        case .error(let err):
            isStreaming = false
            errorMessage = err
        }
    }
}
#endif
