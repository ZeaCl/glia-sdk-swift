import Foundation

/// Representación agnóstica y segura de un mensaje recibido o enviado por WebSocket.
public enum WebSocketMessage: Sendable, Equatable {
    case string(String)
    case data(Data)
}

/// Abstracción del transporte WebSocket para desacoplar `GliaClient` de `URLSessionWebSocketTask`
/// y permitir testing unitario determinista (DIP / Clean Architecture).
public protocol WebSocketConnectionProtocol: Sendable {
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func cancel(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func resume()
}

public extension WebSocketConnectionProtocol {
    func cancel() {
        cancel(closeCode: .normalClosure, reason: nil)
    }
}

/// Factoría para instanciar conexiones WebSocket.
public typealias WebSocketConnectionFactory = @Sendable (URL, URLSession) -> any WebSocketConnectionProtocol

/// Implementación concreta de `WebSocketConnectionProtocol` respaldada por `URLSessionWebSocketTask`.
public final class URLSessionWebSocketConnection: WebSocketConnectionProtocol, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .string(let str):
            try await task.send(.string(str))
        case .data(let data):
            try await task.send(.data(data))
        }
    }

    public func receive() async throws -> WebSocketMessage {
        let msg = try await task.receive()
        switch msg {
        case .string(let str):
            return .string(str)
        case .data(let data):
            return .data(data)
        @unknown default:
            return .string("")
        }
    }

    public func cancel(closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: Data? = nil) {
        task.cancel(with: closeCode, reason: reason)
    }

    public func resume() {
        task.resume()
    }
}

public let defaultWebSocketConnectionFactory: WebSocketConnectionFactory = { url, session in
    URLSessionWebSocketConnection(task: session.webSocketTask(with: url))
}
