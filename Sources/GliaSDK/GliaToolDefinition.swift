import Foundation

/// Declarative definition of a dynamic tool sent to the Glia agent
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

/// Generic container for dynamic Codable values.
/// Recommended to migrate to `JSONValue` for full type safety and concurrency.
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
