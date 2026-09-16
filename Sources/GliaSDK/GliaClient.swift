import Foundation

public protocol GliaClientProtocol: Sendable {
    func connect() async throws
    func disconnect() async
    func send(prompt: String, systemPrompt: String?, tools: [GliaToolDefinition]) async throws
    func observeEvents() async -> AsyncStream<GliaStreamEvent>
}

public actor GliaClient: GliaClientProtocol {
    public let options: GliaOptions
    private let session: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnectedInternal: Bool = false
    private var isJoinedInternal: Bool = false
    private var messageRef: Int = 1
    private var heartbeatTask: Task<Void, Never>?

    private var continuations: [UUID: AsyncStream<GliaStreamEvent>.Continuation] = [:]

    public init(
        options: GliaOptions,
        session: URLSession = .shared
    ) {
        self.options = options
        self.session = session
    }

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        token: String? = nil,
        systemPrompt: String? = nil,
        session: URLSession = .shared
    ) {
        self.options = GliaOptions(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            token: token,
            systemPrompt: systemPrompt
        )
        self.session = session
    }

    public var topic: String {
        "session:\(options.appId):\(options.userId)"
    }

    public var isConnected: Bool {
        isConnectedInternal && isJoinedInternal
    }

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

    public func connect() async throws {
        await disconnect()

        var cleanUrl = options.gatewayUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanUrl.hasSuffix("/socket/websocket") {
            cleanUrl += "/socket/websocket"
        }

        var components = URLComponents(string: cleanUrl)
        var queryItems = [URLQueryItem(name: "vsn", value: "2.0.0")]
        if let token = options.token, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        self.isConnectedInternal = true

        startReceiveLoop()
        try await joinChannel()
        startHeartbeat()
    }

    public func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnectedInternal = false
        isJoinedInternal = false
    }

    private func joinChannel() async throws {
        let ref = String(messageRef)
        messageRef += 1

        let joinFrame: [Any] = [
            ref,
            ref,
            topic,
            "phx_join",
            [String: String]()
        ]

        let data = try JSONSerialization.data(withJSONObject: joinFrame)
        guard let text = String(data: data, encoding: .utf8) else { return }

        try await webSocketTask?.send(.string(text))
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self = self else { break }
                await self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard isConnectedInternal else { return }
        let ref = String(messageRef)
        messageRef += 1

        let frame: [Any] = [NSNull(), ref, "phoenix", "heartbeat", [String: String]()]
        if let data = try? JSONSerialization.data(withJSONObject: frame),
           let text = String(data: data, encoding: .utf8) {
            try? await webSocketTask?.send(.string(text))
        }
    }

    public func send(
        prompt: String,
        systemPrompt: String? = nil,
        tools: [GliaToolDefinition] = []
    ) async throws {
        let ref = String(messageRef)
        messageRef += 1

        var payload: [String: Any] = [
            "message": prompt
        ]

        let effectiveSystemPrompt = systemPrompt ?? options.systemPrompt
        if let sp = effectiveSystemPrompt, !sp.isEmpty {
            payload["system_prompt"] = sp
        }

        if !tools.isEmpty {
            let toolsData = try JSONEncoder().encode(tools)
            if let toolsJson = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]] {
                payload["tools"] = toolsJson
            }
        }

        let frame: [Any] = [
            NSNull(),
            ref,
            topic,
            "run",
            payload
        ]

        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else { return }

        try await webSocketTask?.send(.string(text))
    }

    private func startReceiveLoop() {
        Task { [weak self] in
            while let self = self, await self.isConnectedInternal {
                guard let task = await self.webSocketTask else { break }

                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleIncomingMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleIncomingMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    await self.broadcast(.error("WebSocket error: \(error.localizedDescription)"))
                    break
                }
            }
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 5 else {
            return
        }

        let event = json[3] as? String ?? ""
        let payload = json[4] as? [String: Any] ?? [:]

        switch event {
        case "phx_reply":
            if let status = payload["status"] as? String, status == "ok" {
                self.isJoinedInternal = true
            }

        case "status":
            if let status = payload["status"] as? String {
                broadcast(.status(status))
            }

        case "thinking_delta":
            if let content = payload["content"] as? String {
                broadcast(.thinkingDelta(content))
            }

        case "message_delta":
            if let content = payload["content"] as? String {
                broadcast(.messageDelta(content))
            }

        case "tool_call":
            if let name = payload["name"] as? String {
                let args = payload["args"] as? [String: Any] ?? [:]
                let sendableArgs = args.mapValues { AnySendable($0) }
                broadcast(.toolCall(name: name, args: sendableArgs))
            }

        case "tool_result":
            if let name = payload["name"] as? String {
                let result = payload["result"] ?? ""
                broadcast(.toolResult(name: name, result: AnySendable(result)))
            }

        case "done":
            let fullMsg = payload["full_message"] as? String
            broadcast(.done(fullMessage: fullMsg))

        case "error":
            let msg = payload["message"] as? String ?? "Error desconocido"
            broadcast(.error(msg))

        default:
            break
        }
    }
}
