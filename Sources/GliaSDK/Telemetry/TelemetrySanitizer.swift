import Foundation

/// Utilities to enforce security, Zero PII guidelines, and maximum payload sizes
/// on mobile telemetry events.
public struct TelemetrySanitizer: Sendable {
    public static let maxStringLength: Int = 1_024
    private static let redactedValue: String = "[REDACTED]"

    private static let sensitiveKeySubstrings: [String] = [
        "password",
        "token",
        "secret",
        "authorization",
        "authentication",
        "jwt",
        "email",
        "bearer",
        "auth_token",
        "auth_key",
        "credit_card",
        "card_number",
        "cvv",
        "private_key"
    ]

    private static let emailRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}"#,
        options: []
    )

    private static let jwtRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]+"#,
        options: []
    )

    private static let bearerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"Bearer\s+[A-Za-z0-9\-_.~+/]+=*"#,
        options: [.caseInsensitive]
    )

    /// Truncates string to at most `maxStringLength` (1,024 characters).
    public static func truncate(_ string: String) -> String {
        if string.count <= maxStringLength {
            return string
        }
        return String(string.prefix(maxStringLength))
    }

    /// Checks if a metadata key is considered sensitive.
    public static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower == "auth" || lower.hasPrefix("auth_") || lower.hasSuffix("_auth") {
            return true
        }
        return sensitiveKeySubstrings.contains { lower.contains($0) }
    }

    /// Sanitizes an arbitrary string value by masking PII patterns and truncating.
    public static func sanitizeString(_ input: String) -> String {
        var result = input

        if let bearer = bearerRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = bearer.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "Bearer [REDACTED]")
        }

        if let jwt = jwtRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = jwt.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED_JWT]")
        }

        if let email = emailRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = email.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED_EMAIL]")
        }

        return truncate(result)
    }

    /// Recursively sanitizes a JSONValue against sensitive keys and PII patterns.
    public static func sanitizeJSONValue(_ value: JSONValue, parentKey: String? = nil) -> JSONValue {
        if let key = parentKey, isSensitiveKey(key) {
            return .string(redactedValue)
        }

        switch value {
        case .string(let str):
            return .string(sanitizeString(str))
        case .object(let dict):
            var sanitizedDict: [String: JSONValue] = [:]
            for (k, v) in dict {
                sanitizedDict[k] = sanitizeJSONValue(v, parentKey: k)
            }
            return .object(sanitizedDict)
        case .array(let arr):
            return .array(arr.map { sanitizeJSONValue($0, parentKey: nil) })
        case .number, .bool, .null:
            return value
        }
    }

    /// Sanitizes a metadata dictionary.
    public static func sanitizeMetadata(_ metadata: [String: JSONValue]?) -> [String: JSONValue]? {
        guard let metadata = metadata else { return nil }
        var result: [String: JSONValue] = [:]
        for (key, val) in metadata {
            result[key] = sanitizeJSONValue(val, parentKey: key)
        }
        return result
    }
}
