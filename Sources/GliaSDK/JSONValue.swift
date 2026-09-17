import Foundation

/// Representación fuertemente tipada y segura para concurrencia (`Sendable`) de cualquier valor JSON.
/// Elimina la necesidad de `@unchecked Sendable` sobre `Any` garantizando la seguridad en Swift 6.
public enum JSONValue: Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public var stringValue: String? {
        if case .string(let str) = self { return str }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let num) = self { return num }
        return nil
    }

    public var intValue: Int? {
        if case .number(let num) = self { return Int(num) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self {
            return dict[key]
        }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let arr) = self, index >= 0, index < arr.count {
            return arr[index]
        }
        return nil
    }
}

// MARK: - Codable Conformance
extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .number(Double(intVal))
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .number(doubleVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
        } else if let dictVal = try? container.decode([String: JSONValue].self) {
            self = .object(dictVal)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "No se pudo decodificar JSONValue compatible"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .number(let num):
            if num.rounded() == num && !num.isInfinite && !num.isNaN && num <= Double(Int.max) && num >= Double(Int.min) {
                try container.encode(Int(num))
            } else {
                try container.encode(num)
            }
        case .bool(let b):
            try container.encode(b)
        case .object(let dict):
            try container.encode(dict)
        case .array(let arr):
            try container.encode(arr)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - Expressible Literals Conformance
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

// MARK: - Any / Foundation Conversion Helpers
extension JSONValue {
    /// Inicializa recursivamente un `JSONValue` a partir de un valor genérico (`Any`) como los retornados por `JSONSerialization`.
    public static func fromAny(_ any: Any) -> JSONValue {
        switch any {
        case let json as JSONValue:
            return json
        case let str as String:
            return .string(str)
        case let num as NSNumber:
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            return .number(num.doubleValue)
        case let bool as Bool:
            return .bool(bool)
        case let dict as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (k, v) in dict {
                result[k] = JSONValue.fromAny(v)
            }
            return .object(result)
        case let array as [Any]:
            return .array(array.map { JSONValue.fromAny($0) })
        case is NSNull:
            return .null
        default:
            return .null
        }
    }

    /// Convierte el `JSONValue` a un objeto nativo compatible con `JSONSerialization`.
    public var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.rounded() == n && !n.isInfinite && !n.isNaN && n <= Double(Int.max) && n >= Double(Int.min) {
                return Int(n)
            }
            return n
        case .bool(let b): return b
        case .object(let dict): return dict.mapValues { $0.rawValue }
        case .array(let arr): return arr.map { $0.rawValue }
        case .null: return NSNull()
        }
    }
}
