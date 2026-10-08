import Foundation

/// Types of telemetry records.
public enum TelemetryEventType: String, Sendable, Codable, Equatable {
    case error
    case event
}

/// Represents a single telemetry event or technical error ready for transmission or buffering.
public struct TelemetryEvent: Sendable, Codable, Equatable {
    public let seq: Int
    public let type: TelemetryEventType
    public let name: String
    public let flow: String?
    public let endpoint: String?
    public let message: String?
    public let code: String?
    public let errorType: String?
    public let metadata: [String: JSONValue]?

    public init(
        seq: Int,
        type: TelemetryEventType,
        name: String,
        flow: String? = nil,
        endpoint: String? = nil,
        message: String? = nil,
        code: String? = nil,
        errorType: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.seq = seq
        self.type = type
        self.name = name
        self.flow = flow
        self.endpoint = endpoint
        self.message = message.map { TelemetrySanitizer.sanitizeString($0) }
        self.code = code
        self.errorType = errorType
        self.metadata = TelemetrySanitizer.sanitizeMetadata(metadata)
    }

    /// Helper to construct a sanitized Error telemetry event.
    public static func errorEvent(
        seq: Int,
        flow: String,
        error: Error,
        endpoint: String? = nil,
        code: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) -> TelemetryEvent {
        let errorDesc = error.localizedDescription
        let errorType = String(describing: Swift.type(of: error))
        let effectiveCode = code ?? (error as NSError).domain + "_\((error as NSError).code)"

        return TelemetryEvent(
            seq: seq,
            type: .error,
            name: "error",
            flow: flow,
            endpoint: endpoint,
            message: errorDesc,
            code: effectiveCode,
            errorType: errorType,
            metadata: metadata
        )
    }

    /// Helper to construct a sanitized custom telemetry event.
    public static func customEvent(
        seq: Int,
        name: String,
        flow: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) -> TelemetryEvent {
        return TelemetryEvent(
            seq: seq,
            type: .event,
            name: name,
            flow: flow,
            metadata: metadata
        )
    }

    /// Converts event to Phoenix Channels payload format.
    public func toPhoenixPayload() -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "seq": .number(Double(seq)),
            "type": .string(type.rawValue),
            "name": .string(name)
        ]

        if let flow = flow {
            payload["flow"] = .string(flow)
        }
        if let endpoint = endpoint {
            payload["endpoint"] = .string(endpoint)
        }
        if let message = message {
            payload["message"] = .string(message)
        }
        if let code = code {
            payload["code"] = .string(code)
        }
        if let errorType = errorType {
            payload["error_type"] = .string(errorType)
        }
        if let metadata = metadata {
            payload["metadata"] = .object(metadata)
        }

        return payload
    }
}
