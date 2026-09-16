import Foundation

/// Eventos emitidos en tiempo real por el runtime de Glia a través de WebSocket
public enum GliaStreamEvent: Sendable {
    case status(String)
    case thinkingDelta(String)
    case messageDelta(String)
    case toolCall(name: String, args: [String: AnySendable])
    case toolResult(name: String, result: AnySendable)
    case done(fullMessage: String?)
    case error(String)
}

/// Contenedor de valores dinámicos JSON seguro para concurrencia (`Sendable`)
public struct AnySendable: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}

/// Opciones de configuración para inicializar GliaClient
public struct GliaOptions: Sendable {
    public let gatewayUrl: String
    public let appId: String
    public let userId: String
    public let token: String?
    public let systemPrompt: String?
    public let timeout: TimeInterval

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        token: String? = nil,
        systemPrompt: String? = nil,
        timeout: TimeInterval = 60.0
    ) {
        self.gatewayUrl = gatewayUrl
        self.appId = appId
        self.userId = userId
        self.token = token
        self.systemPrompt = systemPrompt
        self.timeout = timeout
    }
}
