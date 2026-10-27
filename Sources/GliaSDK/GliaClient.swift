import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

public protocol GliaClientProtocol: Sendable {
    var isConnected: Bool { get async }
    func connect() async throws
    func disconnect() async
    func send(prompt: String, systemPrompt: String?, tools: [GliaToolDefinition]) async throws
    func observeEvents() async -> AsyncStream<GliaStreamEvent>
    func trackError(flow: String, error: Error, endpoint: String?, code: String?, metadata: [String: JSONValue]?) async
    func trackEvent(name: String, flow: String?, metadata: [String: JSONValue]?) async
    func fetchHistory(limit: Int, beforeSequence: Int?) async throws -> GliaHistoryResponse
}

public extension GliaClientProtocol {
    func fetchHistory(limit: Int, beforeSequence: Int?) async throws -> GliaHistoryResponse {
        GliaHistoryResponse(messages: [], hasMore: false, sessionId: nil)
    }

    func fetchHistory(limit: Int = 20, beforeSequence: Int? = nil) async throws -> [GliaMessage] {
        let response = try await fetchHistory(limit: limit, beforeSequence: beforeSequence)
        return response.messages
    }

    func send(
        prompt: String,
        systemPrompt: String? = nil,
        tools: [GliaToolDefinition] = []
    ) async throws {
        try await send(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
    }

    func trackError(
        flow: String,
        error: Error,
        endpoint: String? = nil,
        code: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) async {
        // Default no-op for custom protocol implementors/mocks
    }

    func trackError(
        flow: String,
        error: Error,
        endpoint: String? = nil,
        code: String? = nil,
        metadata: [String: Any]?
    ) async {
        let jsonMeta = metadata?.mapValues { JSONValue.fromAny($0) }
        await trackError(flow: flow, error: error, endpoint: endpoint, code: code, metadata: jsonMeta)
    }

    func trackEvent(
        name: String,
        flow: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) async {
        // Default no-op for custom protocol implementors/mocks
    }

    func trackEvent(
        name: String,
        flow: String? = nil,
        metadata: [String: Any]?
    ) async {
        let jsonMeta = metadata?.mapValues { JSONValue.fromAny($0) }
        await trackEvent(name: name, flow: flow, metadata: jsonMeta)
    }
}

public actor GliaClient: GliaClientProtocol {
    private static let sharedLock = NSLock()
    private static var _shared: GliaClient?

    nonisolated public static var shared: GliaClient {
        get {
            sharedLock.lock()
            defer { sharedLock.unlock() }
            if let existing = _shared {
                return existing
            }
            let defaultClient = GliaClient(
                gatewayUrl: "https://api.zea.cl",
                appId: "default",
                userId: "anonymous"
            )
            _shared = defaultClient
            return defaultClient
        }
        set {
            sharedLock.lock()
            defer { sharedLock.unlock() }
            _shared = newValue
        }
    }

    nonisolated public static func configure(shared client: GliaClient) {
        self.shared = client
    }

    nonisolated public let options: GliaOptions
    public let telemetryManager: TelemetryManager
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
    private var isRunActive: Bool = false

    private var continuations: [UUID: AsyncStream<GliaStreamEvent>.Continuation] = [:]
    private var pendingReplies: [String: CheckedContinuation<[String: JSONValue], Error>] = [:]
    #if canImport(UIKit) && !os(watchOS)
    private var lifecycleObservers: [any NSObjectProtocol] = []
    #endif

    public init(
        options: GliaOptions,
        session: URLSession = .shared,
        telemetryManager: TelemetryManager? = nil,
        connectionFactory: @escaping WebSocketConnectionFactory = defaultWebSocketConnectionFactory
    ) {
        self.options = options
        self.session = session
        self.telemetryManager = telemetryManager ?? TelemetryManager()
        self.connectionFactory = connectionFactory
    }

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        sessionId: String? = nil,
        token: String? = nil,
        systemPrompt: String? = nil,
        session: URLSession = .shared,
        telemetryManager: TelemetryManager? = nil,
        connectionFactory: @escaping WebSocketConnectionFactory = defaultWebSocketConnectionFactory
    ) {
        self.options = GliaOptions(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            sessionId: sessionId,
            token: token,
            systemPrompt: systemPrompt
        )
        self.session = session
        self.telemetryManager = telemetryManager ?? TelemetryManager()
        self.connectionFactory = connectionFactory
    }

    public init(
        gatewayUrl: String,
        appId: String,
        userId: String,
        token: String? = nil,
        systemPrompt: String? = nil,
        session: URLSession = .shared,
        telemetryManager: TelemetryManager? = nil,
        connectionFactory: @escaping WebSocketConnectionFactory = defaultWebSocketConnectionFactory
    ) {
        self.init(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            sessionId: nil,
            token: token,
            systemPrompt: systemPrompt,
            session: session,
            telemetryManager: telemetryManager,
            connectionFactory: connectionFactory
        )
    }

    nonisolated public var sessionId: String {
        options.sessionId ?? "\(options.appId):\(options.userId)"
    }

    public var topic: String {
        "session:\(sessionId)"
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
        ensureLifecycleObservers()

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

        removeLifecycleObservers()
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
        broadcast(.status("connected"))
        await flushBufferedTelemetry()
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
        // Auto-reconnect if connection was dropped or not yet established
        if connection == nil || !isConnected {
            try await connect()
        }

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
        isRunActive = true
    }

    // MARK: - Conversation History
    public func fetchHistory(
        limit: Int = 20,
        beforeSequence: Int? = nil
    ) async throws -> GliaHistoryResponse {
        if isConnectedInternal && isJoinedInternal, let conn = connection {
            do {
                return try await fetchHistoryViaWebSocket(limit: limit, beforeSequence: beforeSequence, connection: conn)
            } catch {
                // If websocket fetch failed, fallback to REST
                return try await fetchHistoryViaREST(limit: limit, beforeSequence: beforeSequence)
            }
        } else {
            return try await fetchHistoryViaREST(limit: limit, beforeSequence: beforeSequence)
        }
    }

    private func fetchHistoryViaWebSocket(
        limit: Int,
        beforeSequence: Int?,
        connection: any WebSocketConnectionProtocol
    ) async throws -> GliaHistoryResponse {
        let ref = String(messageRef)
        messageRef += 1

        var payload: [String: JSONValue] = [
            "limit": .number(Double(limit))
        ]
        if let seq = beforeSequence {
            payload["before_sequence"] = .number(Double(seq))
        } else {
            payload["before_sequence"] = .null
        }

        let frame = PhoenixFrame(
            joinRef: nil,
            ref: ref,
            topic: topic,
            event: "get_history",
            payload: payload
        )

        let text = try frame.serialize()
        try await connection.send(.string(text))

        let timeoutSeconds = min(options.timeout, 10.0)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            await self?.failPendingReply(ref: ref, error: GliaError.connectionTimeout)
        }
        defer {
            timeoutTask.cancel()
        }

        let reply = try await withCheckedThrowingContinuation { continuation in
            self.pendingReplies[ref] = continuation
        }

        return try decodeHistoryFromPayload(reply)
    }

    private func decodeHistoryFromPayload(_ payload: [String: JSONValue]) throws -> GliaHistoryResponse {
        let data = try JSONEncoder().encode(JSONValue.object(payload))
        return try JSONDecoder().decode(GliaHistoryResponse.self, from: data)
    }

    private func fetchHistoryViaREST(
        limit: Int,
        beforeSequence: Int?
    ) async throws -> GliaHistoryResponse {
        let url = try buildHistoryRequestURL(limit: limit, beforeSequence: beforeSequence)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = options.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GliaError.serverError("Invalid HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let rawMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            let cleanMsg = String(rawMsg.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GliaError.serverError(cleanMsg)
        }

        return try JSONDecoder().decode(GliaHistoryResponse.self, from: data)
    }

    nonisolated public func buildHistoryRequestURL(limit: Int, beforeSequence: Int?) throws -> URL {
        var trimmed = options.gatewayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed) else {
            throw GliaError.invalidURL(options.gatewayUrl)
        }

        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            components.scheme = "https"
        }

        var path = components.path
        if path.hasSuffix("/socket/websocket") {
            path = String(path.dropLast("/socket/websocket".count))
        } else if path.hasSuffix("/socket") {
            path = String(path.dropLast("/socket".count))
        }
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionId
        components.path = "\(path)/api/conversations/\(encodedSession)/messages"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let seq = beforeSequence {
            queryItems.append(URLQueryItem(name: "before_sequence", value: String(seq)))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw GliaError.invalidURL(options.gatewayUrl)
        }
        return url
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
        // A run is "pending" if we have in-flight RPC replies OR the agent is actively
        // streaming a response (fire-and-forget "run" events are not tracked in pendingReplies).
        let hadPending = !pendingReplies.isEmpty || isRunActive
        if hadPending {
            broadcast(.error("WebSocket error: \(error.localizedDescription)"))
        } else {
            broadcast(.status("disconnected"))
        }
        isRunActive = false

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
                if status == "idle" {
                    isRunActive = false
                }
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
            isRunActive = false
            broadcast(.done(fullMessage: fullMsg))

        case "error":
            let msg = frame.payload["message"]?.stringValue ?? "Error desconocido"
            let code = frame.payload["code"]?.stringValue
            let limitType = frame.payload["limit_type"]?.stringValue ?? "chat"
            if code == "limit_reached" {
                isRunActive = false
                broadcast(.limitReached(message: msg, limitType: limitType))
            } else {
                isRunActive = false
                broadcast(.error(msg))
            }

        case "limit_reached":
            let msg = frame.payload["message"]?.stringValue ?? "Has alcanzado el límite de consultas disponibles."
            let limitType = frame.payload["limit_type"]?.stringValue ?? "chat"
            isRunActive = false
            broadcast(.limitReached(message: msg, limitType: limitType))

        default:
            break
        }
    }

    // MARK: - Telemetry & Error Reporting
    public func trackError(
        flow: String,
        error: Error,
        endpoint: String? = nil,
        code: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) async {
        let effectiveCode = code ?? (error as NSError).domain + "_\((error as NSError).code)"
        let shouldSuppress = await telemetryManager.shouldSuppressError(flow: flow, code: effectiveCode)
        if shouldSuppress {
            return
        }

        let seq = await telemetryManager.nextSequence()
        let event = TelemetryEvent.errorEvent(
            seq: seq,
            flow: flow,
            error: error,
            endpoint: endpoint,
            code: effectiveCode,
            metadata: metadata
        )

        await sendOrBuffer(event: event)
    }

    public func trackEvent(
        name: String,
        flow: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) async {
        let seq = await telemetryManager.nextSequence()
        let event = TelemetryEvent.customEvent(
            seq: seq,
            name: name,
            flow: flow,
            metadata: metadata
        )

        await sendOrBuffer(event: event)
    }

    private func sendOrBuffer(event: TelemetryEvent) async {
        ensureLifecycleObservers()
        if isConnectedInternal && isJoinedInternal, let conn = connection {
            do {
                let ref = String(messageRef)
                messageRef += 1
                let frame = PhoenixFrame(
                    joinRef: nil,
                    ref: ref,
                    topic: topic,
                    event: "track_event",
                    payload: event.toPhoenixPayload()
                )
                let text = try frame.serialize()
                try await conn.send(.string(text))
            } catch {
                await telemetryManager.enqueue(event)
            }
        } else {
            await telemetryManager.enqueue(event)
        }
    }

    private func flushBufferedTelemetry() async {
        guard isConnectedInternal && isJoinedInternal, let conn = connection else { return }
        let pendingEvents = await telemetryManager.flush()
        for event in pendingEvents {
            let ref = String(messageRef)
            messageRef += 1
            let frame = PhoenixFrame(
                joinRef: nil,
                ref: ref,
                topic: topic,
                event: "track_event",
                payload: event.toPhoenixPayload()
            )
            if let text = try? frame.serialize() {
                try? await conn.send(.string(text))
            }
        }
    }

    // MARK: - Lifecycle Management
    private func ensureLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let bgObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleAppDidEnterBackground()
            }
        }

        let fgObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleAppWillEnterForeground()
            }
        }

        lifecycleObservers.append(contentsOf: [bgObserver, fgObserver])
        #endif
    }

    private func removeLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        #endif
    }

    deinit {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
        #endif
    }

    private func handleAppDidEnterBackground() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func handleAppWillEnterForeground() async {
        if isConnectedInternal && isJoinedInternal {
            startHeartbeat()
            await flushBufferedTelemetry()
        } else if !isVoluntaryDisconnect {
            // Silently reconnect when returning to foreground if connection dropped while in background
            reconnectAttempts = 0
            try? await self.connect()
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
        if path.hasSuffix("/socket/websocket") {
            // Already contains the full websocket path
        } else if path.hasSuffix("/socket") {
            path += "/websocket"
        } else {
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

// MARK: - Synchronous Convenience Extensions
public extension GliaClient {
    nonisolated func trackError(
        flow: String,
        error: Error,
        endpoint: String? = nil,
        code: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        let jsonMeta = metadata?.mapValues { JSONValue.fromAny($0) }
        Task {
            await self.trackError(
                flow: flow,
                error: error,
                endpoint: endpoint,
                code: code,
                metadata: jsonMeta
            )
        }
    }

    nonisolated func trackEvent(
        name: String,
        flow: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        let jsonMeta = metadata?.mapValues { JSONValue.fromAny($0) }
        Task {
            await self.trackEvent(
                name: name,
                flow: flow,
                metadata: jsonMeta
            )
        }
    }
}

