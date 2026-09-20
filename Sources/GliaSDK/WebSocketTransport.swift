import Foundation

/// Agnostic and safe representation of a message received or sent over WebSocket.
public enum WebSocketMessage: Sendable, Equatable {
    case string(String)
    case data(Data)
}

/// WebSocket transport abstraction to decouple `GliaClient` from `URLSessionWebSocketTask`
/// and enable deterministic unit testing (DIP / Clean Architecture).
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

/// Factory to instantiate WebSocket connections.
public typealias WebSocketConnectionFactory = @Sendable (URL, URLSession) -> any WebSocketConnectionProtocol

/// Concrete implementation of `WebSocketConnectionProtocol` backed by `URLSessionWebSocketTask`.
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
