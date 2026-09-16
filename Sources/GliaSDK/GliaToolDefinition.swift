import Foundation

/// Definición declarativa de una herramienta (Tool) enviada al agente Glia
public struct GliaToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [String: JSONValue]
    public let webhookUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
        case webhookUrl = "webhook_url"
    }

    public init(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        webhookUrl: String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.webhookUrl = webhookUrl
    }

    @available(*, deprecated, message: "Use init with [String: JSONValue] parameters")
    public init(
        name: String,
        description: String,
        parameters: [String: AnyCodable],
        webhookUrl: String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters.mapValues { $0.toJSONValue }
        self.webhookUrl = webhookUrl
    }
}

/// Contenedor genérico para valores Codable dinámicos.
/// Se recomienda migrar a `JSONValue` para garantizar total seguridad de tipos y concurrencia.
@available(*, deprecated, message: "Use JSONValue instead for strict type safety and Swift 6 concurrency")
public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        self.value = json.rawValue
    }

    public func encode(to encoder: Encoder) throws {
        let json = JSONValue.fromAny(value)
        try json.encode(to: encoder)
    }

    public var toJSONValue: JSONValue {
        JSONValue.fromAny(value)
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.toJSONValue == rhs.toJSONValue
    }
}
