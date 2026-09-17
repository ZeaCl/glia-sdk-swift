import Foundation

/// Eventos emitidos en tiempo real por el runtime de Glia a través de WebSocket
public enum GliaStreamEvent: Sendable, Equatable {
    case status(String)
    case thinkingDelta(String)
    case messageDelta(String)
    case toolCall(name: String, args: [String: JSONValue])
    case toolResult(name: String, result: JSONValue)
    case done(fullMessage: String?)
    case error(String)
}

/// Errores tipados emitidos por el SDK de Glia
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
            return "URL inválida del gateway de Glia: \(url)"
        case .joinFailed(let reason):
            return "No se pudo unir al canal de Phoenix: \(reason)"
        case .connectionTimeout:
            return "Tiempo de espera agotado al conectar o unir canal"
        case .notConnected:
            return "No hay una conexión activa con el gateway de Glia"
        case .connectionClosed(let reason):
            return "Conexión cerrada: \(reason)"
        case .serverError(let msg):
            return "Error del servidor: \(msg)"
        }
    }
}

/// Contenedor de valores dinámicos seguro para concurrencia (`Sendable`).
/// Se recomienda migrar a `JSONValue` para estricta seguridad en tiempo de compilación.
@available(*, deprecated, message: "Use JSONValue instead for strict type and concurrency safety")
public struct AnySendable: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}

/// Opciones de configuración para inicializar GliaClient
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
