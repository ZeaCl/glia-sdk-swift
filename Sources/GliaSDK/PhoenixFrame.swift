import Foundation

/// Representación estructurada de un frame en el protocolo Phoenix Channels v2.
/// Formato de array: `[join_ref, ref, topic, event, payload]`
public struct PhoenixFrame: Sendable, Equatable {
    public let joinRef: String?
    public let ref: String?
    public let topic: String
    public let event: String
    public let payload: [String: JSONValue]

    public init(
        joinRef: String? = nil,
        ref: String? = nil,
        topic: String,
        event: String,
        payload: [String: JSONValue] = [:]
    ) {
        self.joinRef = joinRef
        self.ref = ref
        self.topic = topic
        self.event = event
        self.payload = payload
    }

    /// Parsea un texto JSON que representa un frame de Phoenix v2.
    public static func parse(from text: String) -> PhoenixFrame? {
        guard let data = text.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any],
              jsonArray.count >= 5 else {
            return nil
        }

        let joinRef = jsonArray[0] as? String
        let ref = jsonArray[1] as? String
        let topic = jsonArray[2] as? String ?? ""
        let event = jsonArray[3] as? String ?? ""
        let rawPayload = jsonArray[4]

        let payloadJson = JSONValue.fromAny(rawPayload)
        let payloadDict = payloadJson.objectValue ?? [:]

        return PhoenixFrame(
            joinRef: joinRef,
            ref: ref,
            topic: topic,
            event: event,
            payload: payloadDict
        )
    }

    /// Serializa el frame en formato JSON array para enviarlo por WebSocket.
    public func serialize() throws -> String {
        let rawJoinRef: Any = joinRef ?? NSNull()
        let rawRef: Any = ref ?? NSNull()
        let rawPayload = payload.mapValues { $0.rawValue }

        let array: [Any] = [
            rawJoinRef,
            rawRef,
            topic,
            event,
            rawPayload
        ]

        let data = try JSONSerialization.data(withJSONObject: array)
        guard let str = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "No se pudo codificar PhoenixFrame como UTF-8")
            )
        }
        return str
    }
}
