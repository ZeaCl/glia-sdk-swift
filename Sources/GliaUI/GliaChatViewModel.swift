#if canImport(SwiftUI) && canImport(Combine)
import Foundation
import SwiftUI
import GliaSDK

public struct GliaChatMessage: Identifiable, Sendable, Codable {
    public let id: UUID
    public let role: GliaMessageRole
    public let content: String
    public let thinking: String?
    public let toolName: String?
    public let sequence: Int?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: GliaMessageRole,
        content: String,
        thinking: String? = nil,
        toolName: String? = nil,
        sequence: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolName = toolName
        self.sequence = sequence
        self.timestamp = timestamp
    }

    public init(from message: GliaMessage) {
        self.id = UUID(uuidString: message.id) ?? UUID()
        self.role = message.role
        self.content = message.content
        self.thinking = message.thinking
        self.toolName = message.toolName
        self.sequence = message.sequence
        self.timestamp = message.insertedAt ?? Date()
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
    @Published public private(set) var hasMoreMessages: Bool = false
    @Published public private(set) var isLoadingHistory: Bool = false

    public static let defaultErrorMessage: String = "We are currently experiencing difficulties and cannot process your request. Please try again in a few moments."

    public var onMessagesUpdated: (([GliaChatMessage]) -> Void)?
    public var errorSanitizer: ((Error) -> String)?
    public var onError: ((Error) -> Void)?
    public let autoLoadHistory: Bool

    private var lastSentPrompt: String?
    private var lastSentSystemPrompt: String?
    private var lastSentTools: [GliaToolDefinition] = []
    private var lastExecutedTool: String? = nil
    private let client: GliaClientProtocol
    private var eventsTask: Task<Void, Never>?

    public init(
        client: GliaClientProtocol,
        initialMessages: [GliaChatMessage] = [],
        autoLoadHistory: Bool = true,
        onMessagesUpdated: (([GliaChatMessage]) -> Void)? = nil
    ) {
        self.client = client
        self.messages = initialMessages
        self.autoLoadHistory = autoLoadHistory
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
            defer { self?.eventsTask = nil }
            guard let self = self else { return }

            do {
                try await self.client.connect()
                self.isConnected = true
                self.errorMessage = nil

                let stream = await self.client.observeEvents()

                if self.autoLoadHistory {
                    Task { [weak self] in
                        await self?.loadInitialHistory()
                    }
                }

                for await event in stream {
                    self.handleEvent(event)
                }
            } catch {
                self.isConnected = false
                self.errorMessage = self.formatError(error)
            }
        }
    }

    // MARK: - Conversation History & Pagination
    public func loadInitialHistory(limit: Int = 20) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let response = try await client.fetchHistory(limit: limit, beforeSequence: nil)
            self.hasMoreMessages = response.hasMore

            if !response.messages.isEmpty {
                let sorted = response.messages.sorted { m1, m2 in
                    if let s1 = m1.sequence, let s2 = m2.sequence {
                        return s1 < s2
                    }
                    if let d1 = m1.insertedAt, let d2 = m2.insertedAt {
                        return d1 < d2
                    }
                    return false
                }
                let fetchedChatMessages = sorted.map { GliaChatMessage(from: $0) }

                if self.messages.isEmpty {
                    self.messages = fetchedChatMessages
                    self.onMessagesUpdated?(self.messages)
                } else {
                    let existingIds = Set(self.messages.map { $0.id })
                    let newMessages = fetchedChatMessages.filter { !existingIds.contains($0.id) }
                    if !newMessages.isEmpty {
                        var combined = newMessages
                        combined.append(contentsOf: self.messages)
                        self.messages = combined
                        self.onMessagesUpdated?(self.messages)
                    }
                }
            }
        } catch {
            // Non-fatal error during background history loading
        }
    }

    public func fetchOlderMessages(limit: Int = 20) async {
        guard !isLoadingHistory, hasMoreMessages else { return }
        let minSequence = messages.compactMap { $0.sequence }.min()

        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let response = try await client.fetchHistory(limit: limit, beforeSequence: minSequence)
            self.hasMoreMessages = response.hasMore

            if !response.messages.isEmpty {
                let sorted = response.messages.sorted { m1, m2 in
                    if let s1 = m1.sequence, let s2 = m2.sequence {
                        return s1 < s2
                    }
                    if let d1 = m1.insertedAt, let d2 = m2.insertedAt {
                        return d1 < d2
                    }
                    return false
                }
                let olderMessages = sorted.map { GliaChatMessage(from: $0) }
                let existingIds = Set(self.messages.map { $0.id })
                let filtered = olderMessages.filter { !existingIds.contains($0.id) }
                if !filtered.isEmpty {
                    var updated = filtered
                    updated.append(contentsOf: self.messages)
                    self.messages = updated
                    self.onMessagesUpdated?(self.messages)
                }
            }
        } catch {
            // Non-fatal pagination error
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

    public func retryLastSend() {
        if let prompt = lastSentPrompt {
            sendInternal(prompt: prompt, systemPrompt: lastSentSystemPrompt, tools: lastSentTools, isRetry: true)
        } else {
            connect()
        }
    }

    public func send(prompt: String, systemPrompt: String? = nil, tools: [GliaToolDefinition] = []) {
        sendInternal(prompt: prompt, systemPrompt: systemPrompt, tools: tools, isRetry: false)
    }

    private func sendInternal(prompt: String, systemPrompt: String?, tools: [GliaToolDefinition], isRetry: Bool) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        self.lastSentPrompt = trimmed
        self.lastSentSystemPrompt = systemPrompt
        self.lastSentTools = tools

        if !isRetry {
            let userMsg = GliaChatMessage(role: .user, content: trimmed)
            messages.append(userMsg)
            onMessagesUpdated?(messages)
        }

        isStreaming = true
        currentThinking = ""
        currentText = ""
        currentTool = nil
        lastExecutedTool = nil
        errorMessage = nil

        Task { [weak self] in
            guard let self = self else { return }
            do {
                if !self.isConnected {
                    try await self.client.connect()
                    self.isConnected = true
                    self.startEventsStreamIfNeeded()
                }
                try await self.client.send(prompt: trimmed, systemPrompt: systemPrompt, tools: tools)
            } catch {
                self.isStreaming = false
                self.errorMessage = self.formatError(error)
            }
        }
    }

    private func startEventsStreamIfNeeded() {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            defer { self?.eventsTask = nil }
            guard let self = self else { return }
            let stream = await self.client.observeEvents()
            for await event in stream {
                self.handleEvent(event)
            }
        }
    }

    private func formatError(_ error: Error) -> String {
        onError?(error)
        if let custom = errorSanitizer?(error) {
            return custom
        }

        let desc: String
        if case GliaError.serverError(let msg) = error {
            desc = msg
        } else {
            desc = error.localizedDescription
        }

        let lower = desc.lowercased()
        if lower.contains("glia") || lower.contains("gateway") || lower.contains("phoenix") || lower.contains("websocket") {
            return Self.defaultErrorMessage
        }
        return desc
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
            errorMessage = formatError(GliaError.serverError(err))
        }
    }
}
#endif
