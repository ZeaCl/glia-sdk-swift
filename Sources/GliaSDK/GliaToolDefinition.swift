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
public struct AnyCodable: Codable, Sendable, Equatable {
    private let json: JSONValue

    public var value: Any {
        json.rawValue
    }

    public init(_ value: Any) {
        self.json = JSONValue.fromAny(value)
    }

    public init(from decoder: Decoder) throws {
        self.json = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    public var toJSONValue: JSONValue {
        json
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.json == rhs.json
    }
}
