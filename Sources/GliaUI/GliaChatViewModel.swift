#if canImport(SwiftUI) && canImport(Combine)
import Foundation
import SwiftUI
import GliaSDK
#if canImport(CryptoKit)
import CryptoKit
#endif

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
        self.id = Self.deterministicUUID(from: message.id)
        self.role = message.role
        self.content = message.content
        self.thinking = message.thinking
        self.toolName = message.toolName
        self.sequence = message.sequence
        self.timestamp = message.insertedAt ?? Date()
    }

    public static func deterministicUUID(from string: String) -> UUID {
        if let uuid = UUID(uuidString: string) {
            return uuid
        }
        #if canImport(CryptoKit)
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0F) | 0x30 // UUID v3 (MD5 based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        #else
        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8 = Array(string.utf8)
        for (i, byte) in utf8.enumerated() {
            bytes[i % 16] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        #endif
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
                self.mergeHistoryMessages(fetchedChatMessages)
            }
        } catch {
            onError?(error)
            Task { [weak self] in
                await self?.client.trackError(
                    flow: "chat_history",
                    error: error,
                    endpoint: "get_history",
                    code: nil,
                    metadata: ["operation": .string("initial_load")]
                )
            }
        }
    }

    private func mergeHistoryMessages(_ fetchedChatMessages: [GliaChatMessage]) {
        if self.messages.isEmpty {
            self.messages = fetchedChatMessages
            self.onMessagesUpdated?(self.messages)
            return
        }

        var result: [GliaChatMessage] = []
        var existingUnmatched = self.messages

        for historyMsg in fetchedChatMessages {
            if let matchedIndex = existingUnmatched.firstIndex(where: { existing in
                if existing.id == historyMsg.id { return true }
                if existing.role == historyMsg.role &&
                   existing.content.trimmingCharacters(in: .whitespacesAndNewlines) == historyMsg.content.trimmingCharacters(in: .whitespacesAndNewlines) {
                    if existing.sequence == nil || existing.sequence == historyMsg.sequence {
                        let timeDiff = abs(historyMsg.timestamp.timeIntervalSince(existing.timestamp))
                        return timeDiff < 60.0
                    }
                }
                return false
            }) {
                // Replace local unsequenced message with official historical message
                result.append(historyMsg)
                existingUnmatched.remove(at: matchedIndex)
            } else {
                result.append(historyMsg)
            }
        }

        result.append(contentsOf: existingUnmatched)
        self.messages = result
        self.onMessagesUpdated?(self.messages)
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
            onError?(error)
            Task { [weak self] in
                await self?.client.trackError(
                    flow: "chat_history",
                    error: error,
                    endpoint: "get_history",
                    code: nil,
                    metadata: ["operation": .string("pagination")]
                )
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
