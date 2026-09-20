import Foundation

public protocol GliaClientProtocol: Sendable {
    var isConnected: Bool { get async }
    func connect() async throws
    func disconnect() async
    func send(prompt: String, systemPrompt: String?, tools: [GliaToolDefinition]) async throws
    func observeEvents() async -> AsyncStream<GliaStreamEvent>
}

public extension GliaClientProtocol {
    func send(
        prompt: String,
        systemPrompt: String? = nil,
        tools: [GliaToolDefinition] = []
    ) async throws {
        try await send(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
    }
}

public actor GliaClient: GliaClientProtocol {
    public let options: GliaOptions
    private let session: URLSession
    private let connectionFactory: WebSocketConnectionFactory

    private var connection: (any WebSocketConnectionProtocol)?
    private var isConnectedInternal: Bool = false
    private var isJoinedInternal: Bool = false
    private var isVoluntaryDisconnect: Bool = false
    private var messageRef: Int = 1
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts: Int = 0

    private var continuations: [UUID: AsyncStream<GliaStreamEvent>.Continuation] = [:]
    private var pendingReplies: [String: CheckedContinuation<[String: JSONValue], Error>] = [:]

    public init(
        options: GliaOptions,
        session: URLSession = .shared,
        connectionFactory: @escaping WebSocketConnectionFactory = defaultWebSocketConnectionFactory
    ) {
        self.options = options
        self.session = session
        self.connectionFactory = connectionFactory
    }

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        token: String? = nil,
        systemPrompt: String? = nil,
        session: URLSession = .shared,
        connectionFactory: @escaping WebSocketConnectionFactory = defaultWebSocketConnectionFactory
    ) {
        self.options = GliaOptions(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            token: token,
            systemPrompt: systemPrompt
        )
        self.session = session
        self.connectionFactory = connectionFactory
    }

    public var topic: String {
        "session:\(options.appId):\(options.userId)"
    }

    public var isConnected: Bool {
        isConnectedInternal && isJoinedInternal
    }

    // MARK: - Event Observation
    public func observeEvents() async -> AsyncStream<GliaStreamEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: GliaStreamEvent) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    // MARK: - Connection Lifecycle
    public func connect() async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        isVoluntaryDisconnect = false

        let url = try Self.normalizeGatewayURL(options.gatewayUrl, token: options.token)

        // Cancel previous connection if exists
        cancelInternalConnection()

        let conn = connectionFactory(url, session)
        self.connection = conn
        conn.resume()
        self.isConnectedInternal = true

        startReceiveLoop(for: conn)

        do {
            try await joinChannel()
            self.reconnectAttempts = 0
            startHeartbeat()
        } catch {
            cancelInternalConnection()
            throw error
        }
    }

    public func disconnect() async {
        isVoluntaryDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil

        cancelInternalConnection()

        // Finish event streams to avoid memory leaks (AsyncStream leak fix)
        for cont in continuations.values {
            cont.finish()
        }
        continuations.removeAll()

        // Cancel pending phx_reply continuations
        for reply in pendingReplies.values {
            reply.resume(throwing: GliaError.connectionClosed("Voluntary disconnection"))
        }
        pendingReplies.removeAll()
    }

    private func cancelInternalConnection() {
        receiveTask?.cancel()
        receiveTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        connection?.cancel()
        connection = nil

        isConnectedInternal = false
        isJoinedInternal = false
    }

    // MARK: - Phoenix Join Handshake
    private func joinChannel() async throws {
        guard let conn = connection else {
            throw GliaError.notConnected
        }

        let ref = String(messageRef)
        messageRef += 1

        let frame = PhoenixFrame(
            joinRef: ref,
            ref: ref,
            topic: topic,
            event: "phx_join",
            payload: [:]
        )

        let text = try frame.serialize()
        try await conn.send(.string(text))

        // Synchronously wait for phx_reply confirmation with timeout
        let timeoutSeconds = options.timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            await self?.failPendingReply(ref: ref, error: GliaError.connectionTimeout)
        }

        defer {
            timeoutTask.cancel()
        }

        _ = try await withCheckedThrowingContinuation { continuation in
            self.pendingReplies[ref] = continuation
        }

        self.isJoinedInternal = true
    }

    private func failPendingReply(ref: String, error: Error) {
        if let continuation = pendingReplies.removeValue(forKey: ref) {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Heartbeat
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self = self, !Task.isCancelled else { break }
                await self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard isConnectedInternal, let conn = connection else { return }
        let ref = String(messageRef)
        messageRef += 1

        let frame = PhoenixFrame(
            joinRef: nil,
            ref: ref,
            topic: "phoenix",
            event: "heartbeat",
            payload: [:]
        )

        if let text = try? frame.serialize() {
            try? await conn.send(.string(text))
        }
    }

    // MARK: - Send Message / Run Prompt
    public func send(
        prompt: String,
        systemPrompt: String? = nil,
        tools: [GliaToolDefinition] = []
    ) async throws {
        guard let conn = connection, isConnected else {
            throw GliaError.notConnected
        }

        let ref = String(messageRef)
        messageRef += 1

        var payload: [String: JSONValue] = [
            "message": .string(prompt)
        ]

        let effectiveSystemPrompt = systemPrompt ?? options.systemPrompt
        if let sp = effectiveSystemPrompt, !sp.isEmpty {
            payload["system_prompt"] = .string(sp)
        }

        if !tools.isEmpty {
            let toolsData = try JSONEncoder().encode(tools)
            if let decodedJson = try? JSONDecoder().decode([JSONValue].self, from: toolsData) {
                payload["tools"] = .array(decodedJson)
            }
        }

        let frame = PhoenixFrame(
            joinRef: nil,
            ref: ref,
            topic: topic,
            event: "run",
            payload: payload
        )

        let text = try frame.serialize()
        try await conn.send(.string(text))
    }

    // MARK: - Receive Loop
    private func startReceiveLoop(for conn: any WebSocketConnectionProtocol) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while let self = self {
                let isConnected = await self.isConnectedInternal
                guard isConnected, !Task.isCancelled else { break }

                do {
                    let message = try await conn.receive()
                    guard !Task.isCancelled else { break }
                    switch message {
                    case .string(let text):
                        await self.handleIncomingMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleIncomingMessage(text)
                        }
                    }
                } catch {
                    let voluntary = await self.isVoluntaryDisconnect
                    if voluntary || Task.isCancelled {
                        // Intentional disconnect by client.disconnect(): exit silently
                        break
                    }

                    await self.handleUnexpectedDisconnection(error: error)
                    break
                }
            }
        }
    }

    private func handleUnexpectedDisconnection(error: Error) {
        cancelInternalConnection()
        broadcast(.error("WebSocket error: \(error.localizedDescription)"))

        // Cancel pending continuations if socket dropped
        for reply in pendingReplies.values {
            reply.resume(throwing: GliaError.connectionClosed(error.localizedDescription))
        }
        pendingReplies.removeAll()

        // Automatic exponential reconnection
        if options.autoReconnect && reconnectAttempts < options.maxReconnectAttempts {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let delayFactor = pow(2.0, Double(attempt - 1))
        let delay = min(options.initialReconnectDelay * delayFactor, options.maxReconnectDelay)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }

            await self.broadcast(.status("reconnecting"))
            do {
                try await self.connect()
            } catch {
                // If it fails, receiveLoop or catch will retry up to maxReconnectAttempts
            }
        }
    }

    // MARK: - Message Handling
    private func handleIncomingMessage(_ text: String) {
        guard let frame = PhoenixFrame.parse(from: text) else { return }

        switch frame.event {
        case "phx_reply":
            let ref = frame.ref ?? ""
            if let continuation = pendingReplies.removeValue(forKey: ref) {
                let status = frame.payload["status"]?.stringValue ?? ""
                if status == "ok" {
                    let response = frame.payload["response"]?.objectValue ?? [:]
                    continuation.resume(returning: response)
                } else {
                    let reason = frame.payload["response"]?["reason"]?.stringValue
                        ?? frame.payload["response"]?["message"]?.stringValue
                        ?? status
                    continuation.resume(throwing: GliaError.joinFailed(reason: reason))
                }
            }

        case "status":
            if let status = frame.payload["status"]?.stringValue {
                broadcast(.status(status))
            }

        case "thinking_delta":
            if let content = frame.payload["content"]?.stringValue {
                broadcast(.thinkingDelta(content))
            }

        case "message_delta":
            if let content = frame.payload["content"]?.stringValue {
                broadcast(.messageDelta(content))
            }

        case "tool_call":
            if let name = frame.payload["name"]?.stringValue {
                let args = frame.payload["args"]?.objectValue ?? [:]
                broadcast(.toolCall(name: name, args: args))
            }

        case "tool_result":
            if let name = frame.payload["name"]?.stringValue {
                let result = frame.payload["result"] ?? .null
                broadcast(.toolResult(name: name, result: result))
            }

        case "done":
            let fullMsg = frame.payload["text"]?.stringValue ?? frame.payload["full_message"]?.stringValue
            broadcast(.done(fullMessage: fullMsg))

        case "error":
            let msg = frame.payload["message"]?.stringValue ?? "Error desconocido"
            broadcast(.error(msg))

        default:
            break
        }
    }

    // MARK: - URL Normalization
    public static func normalizeGatewayURL(_ urlString: String, token: String? = nil) throws -> URL {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "wss://" + trimmed
        }

        guard var components = URLComponents(string: trimmed) else {
            throw GliaError.invalidURL(urlString)
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            components.scheme = "wss"
        }

        var path = components.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if !path.hasSuffix("/socket/websocket") {
            path += "/socket/websocket"
        }
        components.path = path

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "vsn" }) {
            queryItems.append(URLQueryItem(name: "vsn", value: "2.0.0"))
        }
        if let token = token, !token.isEmpty, !queryItems.contains(where: { $0.name == "token" }) {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw GliaError.invalidURL(urlString)
        }
        return url
    }
}
