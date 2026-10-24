import Foundation

/// Real-time streaming events emitted by the Glia runtime via WebSocket
public enum GliaStreamEvent: Sendable, Equatable {
    case status(String)
    case thinkingDelta(String)
    case messageDelta(String)
    case toolCall(name: String, args: [String: JSONValue])
    case toolResult(name: String, result: JSONValue)
    case done(fullMessage: String?)
    case error(String)
}

/// Typed errors emitted by the Glia SDK
public enum GliaError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case joinFailed(reason: String)
    case connectionTimeout
    case notConnected
    case connectionClosed(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid Glia gateway URL: \(url)"
        case .joinFailed(let reason):
            return "Failed to join Phoenix channel: \(reason)"
        case .connectionTimeout:
            return "Connection or channel join timed out"
        case .notConnected:
            return "No active connection to the Glia gateway"
        case .connectionClosed(let reason):
            return "Connection closed: \(reason)"
        case .serverError(let msg):
            return "Server error: \(msg)"
        }
    }
}

/// Concurrency-safe container for dynamic values (`Sendable`).
/// Recommended to migrate to `JSONValue` for strict compile-time safety.
@available(*, deprecated, message: "Use JSONValue instead for strict type and concurrency safety")
public struct AnySendable: Sendable {
    private let json: JSONValue

    public var value: Any {
        json.rawValue
    }

    public init(_ value: Any) {
        self.json = JSONValue.fromAny(value)
    }
}

/// Message roles for Glia conversations
public enum GliaMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// A conversation message exchanged with Glia runtime or stored in conversation history
public struct GliaMessage: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let role: GliaMessageRole
    public let content: String
    public let sequence: Int?
    public let insertedAt: Date?
    public let thinking: String?
    public let toolName: String?

    public init(
        id: String = UUID().uuidString,
        role: GliaMessageRole,
        content: String,
        sequence: Int? = nil,
        insertedAt: Date? = nil,
        thinking: String? = nil,
        toolName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.sequence = sequence
        self.insertedAt = insertedAt
        self.thinking = thinking
        self.toolName = toolName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case sequence
        case insertedAt = "inserted_at"
        case thinking
        case toolName = "tool_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.role = try container.decode(GliaMessageRole.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
        self.thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)

        if let dateString = try container.decodeIfPresent(String.self, forKey: .insertedAt) {
            self.insertedAt = ISO8601DateFormatter.gliaDate(from: dateString)
        } else {
            self.insertedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(sequence, forKey: .sequence)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        if let insertedAt = insertedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: insertedAt), forKey: .insertedAt)
        }
    }
}

/// History payload returned by WebSocket or REST endpoint
public struct GliaHistoryResponse: Sendable, Codable, Equatable {
    public let messages: [GliaMessage]
    public let hasMore: Bool
    public let sessionId: String?

    public init(messages: [GliaMessage], hasMore: Bool, sessionId: String? = nil) {
        self.messages = messages
        self.hasMore = hasMore
        self.sessionId = sessionId
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
        case sessionId = "session_id"
    }
}

extension ISO8601DateFormatter {
    private static let gliaFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let gliaStandardFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func gliaDate(from string: String) -> Date? {
        if let date = gliaFractionalFormatter.date(from: string) {
            return date
        }
        return gliaStandardFormatter.date(from: string)
    }
}

/// Configuration options to initialize GliaClient
public struct GliaOptions: Sendable, Equatable {
    public let gatewayUrl: String
    public let appId: String
    public let userId: String
    public let sessionId: String?
    public let token: String?
    public let systemPrompt: String?
    public let timeout: TimeInterval
    public let autoReconnect: Bool
    public let maxReconnectAttempts: Int
    public let initialReconnectDelay: TimeInterval
    public let maxReconnectDelay: TimeInterval

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        sessionId: String? = nil,
        token: String? = nil,
        systemPrompt: String? = nil,
        timeout: TimeInterval = 60.0,
        autoReconnect: Bool = true,
        maxReconnectAttempts: Int = 5,
        initialReconnectDelay: TimeInterval = 1.0,
        maxReconnectDelay: TimeInterval = 30.0
    ) {
        self.gatewayUrl = gatewayUrl
        self.appId = appId
        self.userId = userId
        self.sessionId = sessionId
        self.token = token
        self.systemPrompt = systemPrompt
        self.timeout = timeout
        self.autoReconnect = autoReconnect
        self.maxReconnectAttempts = maxReconnectAttempts
        self.initialReconnectDelay = initialReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
    }

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        token: String? = nil,
        systemPrompt: String? = nil,
        timeout: TimeInterval = 60.0,
        autoReconnect: Bool = true,
        maxReconnectAttempts: Int = 5,
        initialReconnectDelay: TimeInterval = 1.0,
        maxReconnectDelay: TimeInterval = 30.0
    ) {
        self.init(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            sessionId: nil,
            token: token,
            systemPrompt: systemPrompt,
            timeout: timeout,
            autoReconnect: autoReconnect,
            maxReconnectAttempts: maxReconnectAttempts,
            initialReconnectDelay: initialReconnectDelay,
            maxReconnectDelay: maxReconnectDelay
        )
    }
}
