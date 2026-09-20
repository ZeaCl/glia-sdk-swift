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

/// Configuration options to initialize GliaClient
public struct GliaOptions: Sendable, Equatable {
    public let gatewayUrl: String
    public let appId: String
    public let userId: String
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
        self.token = token
        self.systemPrompt = systemPrompt
        self.timeout = timeout
        self.autoReconnect = autoReconnect
        self.maxReconnectAttempts = maxReconnectAttempts
        self.initialReconnectDelay = initialReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
    }
}
