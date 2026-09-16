import Foundation

/// Definición declarativa de una herramienta (Tool) enviada al agente Glia
public struct GliaToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: AnyCodable]
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
        parameters: [String: AnyCodable],
        webhookUrl: String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.webhookUrl = webhookUrl
    }
}

/// Contenedor genérico para valores Codable dinámicos
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String:
            try container.encode(s)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let b as Bool:
            try container.encode(b)
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        case let array as [AnyCodable]:
            try container.encode(array)
        default:
            try container.encodeNil()
        }
    }
}
