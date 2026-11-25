import Foundation

/// Any JSON value. App Store Connect speaks JSON:API, where one response mixes
/// resources of many types, so the client reads into this first and maps the
/// parts it needs into typed models.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let n): Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var date: Date? {
        guard let s = string else { return nil }
        return JSONValue.parseDate(s)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
