import Foundation
@testable import GliaSDK

public final class MockWebSocketConnection: WebSocketConnectionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var incomingQueue: [WebSocketMessage] = []
    private var receiveContinuations: [CheckedContinuation<WebSocketMessage, Error>] = []
    private var _sentMessages: [WebSocketMessage] = []
    private var _isResumed: Bool = false
    private var _isCancelled: Bool = false
    private var _cancelCloseCode: URLSessionWebSocketTask.CloseCode?

    public var sentMessages: [WebSocketMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _sentMessages
    }

    public var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isResumed
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public init() {}

    public func pushIncoming(text: String) {
        pushIncoming(message: .string(text))
    }

    public func pushIncoming(message: WebSocketMessage) {
        lock.lock()
        if !receiveContinuations.isEmpty {
            let continuation = receiveContinuations.removeFirst()
            lock.unlock()
            continuation.resume(returning: message)
        } else {
            incomingQueue.append(message)
            lock.unlock()
        }
    }

    public func pushError(_ error: Error) {
        lock.lock()
        let continuations = receiveContinuations
        receiveContinuations.removeAll()
        lock.unlock()
        for cont in continuations {
            cont.resume(throwing: error)
        }
    }

    private func appendSentMessage(_ message: WebSocketMessage) {
        lock.lock()
        defer { lock.unlock() }
        _sentMessages.append(message)
    }

    public func send(_ message: WebSocketMessage) async throws {
        appendSentMessage(message)
    }

    private func dequeueOrRegisterContinuation(_ continuation: CheckedContinuation<WebSocketMessage, Error>) {
        lock.lock()
        defer { lock.unlock() }

        if _isCancelled {
            continuation.resume(throwing: URLError(.cancelled))
            return
        }

        if !incomingQueue.isEmpty {
            let msg = incomingQueue.removeFirst()
            continuation.resume(returning: msg)
        } else {
            receiveContinuations.append(continuation)
        }
    }

    public func receive() async throws -> WebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            dequeueOrRegisterContinuation(continuation)
        }
    }

    public func cancel(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        _isCancelled = true
        _cancelCloseCode = closeCode
        let continuations = receiveContinuations
        receiveContinuations.removeAll()
        lock.unlock()

        for cont in continuations {
            cont.resume(throwing: URLError(.cancelled))
        }
    }

    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        _isResumed = true
    }
}
