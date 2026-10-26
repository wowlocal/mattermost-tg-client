import Foundation

/// A coding key for arbitrary string keys (dictionaries with dynamic keys).
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Lenient decoding helpers.
///
/// Server versions differ in which fields they send, and some send `null` for
/// empty collections. Every model decodes its fields through these helpers so a
/// missing, `null` or mistyped optional field falls back to a default instead of
/// failing the whole response. Only identifiers are decoded strictly.
extension KeyedDecodingContainer {
    /// The value for `key` if present and well-formed, otherwise nil.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard contains(key) else { return nil }
        return try? decodeIfPresent(type, forKey: key)
    }

    func json(_ key: Key) -> JSONValue? {
        lenient(JSONValue.self, key)
    }

    func string(_ key: Key) -> String {
        optionalString(key) ?? ""
    }

    /// Accepts strings, and scalars rendered as strings.
    func optionalString(_ key: Key) -> String? {
        if let value = lenient(String.self, key) { return value }
        return json(key)?.scalarString
    }

    func int64(_ key: Key) -> Int64 {
        optionalInt64(key) ?? 0
    }

    /// Accepts integers, integral doubles and numeric strings.
    func optionalInt64(_ key: Key) -> Int64? {
        if let value = lenient(Int64.self, key) { return value }
        return json(key)?.int64Value
    }

    func int(_ key: Key) -> Int {
        optionalInt(key) ?? 0
    }

    func optionalInt(_ key: Key) -> Int? {
        optionalInt64(key).flatMap { Int(exactly: $0) }
    }

    func optionalDouble(_ key: Key) -> Double? {
        if let value = lenient(Double.self, key) { return value }
        return json(key)?.doubleValue
    }

    func bool(_ key: Key) -> Bool {
        optionalBool(key) ?? false
    }

    /// Accepts booleans, `"true"`/`"false"` and `0`/`1`.
    func optionalBool(_ key: Key) -> Bool? {
        if let value = lenient(Bool.self, key) { return value }
        return json(key)?.boolValue
    }

    func array<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        optionalArray(type, key) ?? []
    }

    /// Decodes an array, skipping elements that fail to decode. Nil when the key
    /// is missing, `null` or not an array.
    func optionalArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        guard contains(key),
              (try? decodeNil(forKey: key)) == false,
              var container = try? nestedUnkeyedContainer(forKey: key)
        else { return nil }
        var result: [T] = []
        while !container.isAtEnd {
            if let element = try? container.decode(T.self) {
                result.append(element)
            } else if (try? container.decode(JSONValue.self)) == nil {
                // Could not even skip the element; stop rather than loop forever.
                break
            }
        }
        return result
    }

    /// Decodes a dictionary, skipping entries that fail to decode.
    func dictionary<T: Decodable>(_ type: T.Type, _ key: Key) -> [String: T] {
        guard contains(key),
              (try? decodeNil(forKey: key)) == false,
              let container = try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        else { return [:] }
        var result: [String: T] = [:]
        for entryKey in container.allKeys {
            if let value = try? container.decode(T.self, forKey: entryKey) {
                result[entryKey.stringValue] = value
            }
        }
        return result
    }

    /// Mattermost `StringMap` fields. Non-string scalars are converted, nested
    /// values are dropped.
    func stringMap(_ key: Key) -> [String: String] {
        guard let object = json(key)?.objectValue else { return [:] }
        return object.compactMapValues { $0.scalarString }
    }

    func jsonObject(_ key: Key) -> [String: JSONValue] {
        json(key)?.objectValue ?? [:]
    }
}

extension Decoder {
    /// A container keyed by arbitrary strings, for models whose JSON keys vary in
    /// case between server versions.
    func anyKeyContainer() throws -> KeyedDecodingContainer<AnyCodingKey> {
        try container(keyedBy: AnyCodingKey.self)
    }
}
