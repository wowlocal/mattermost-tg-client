import Foundation

/// A free-form JSON value.
///
/// Used for `Post.props`, WebSocket event data and other payloads whose shape
/// varies between server versions, plugins and integrations.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Accessors

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The string payload, without coercion.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Integer value; accepts integral doubles and numeric strings.
    public var int64Value: Int64? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
            return Int64(value)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let int = Int64(trimmed) { return int }
            if let double = Double(trimmed) { return JSONValue.double(double).int64Value }
            return nil
        default:
            return nil
        }
    }

    public var intValue: Int? {
        int64Value.flatMap { Int(exactly: $0) }
    }

    /// Floating point value; accepts integers and numeric strings.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Boolean value; accepts `"true"`/`"false"` strings and `0`/`1`, which some
    /// server settings and plugin props use.
    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .int(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        case .string(let value):
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Scalars rendered as strings (`1` → `"1"`, `true` → `"true"`); nil for
    /// null, arrays and objects.
    public var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value):
            if let int = Int64(exactly: value) { return String(int) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Conversion

extension JSONValue {
    /// Creates a value from any `Encodable`.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Re-decodes this value as `T`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Mattermost often embeds JSON documents as strings (for example the `post`
    /// field of the `posted` WebSocket event). Decodes `T` from such a string,
    /// or directly when the value is already structured.
    public func decodeEmbedded<T: Decodable>(_ type: T.Type) throws -> T {
        if case .string(let string) = self {
            return try JSONDecoder().decode(T.self, from: Data(string.utf8))
        }
        return try decode(T.self)
    }

    /// Parses a JSON document.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
