import Foundation

/// A small `Sendable` JSON tree. Remote JSON is only ever *data*: it is parsed, never evaluated (ADR §70).
public enum JSONValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }
    public var int: Int? { double.flatMap { $0.isFinite && abs($0) < 1e15 ? Int($0) : nil } }

    /// Walks `keys`; a purely numeric key indexes arrays.
    public func at(_ keys: String...) -> JSONValue? {
        var node: JSONValue? = self
        for key in keys {
            if let i = Int(key) { node = node?[i] } else { node = node?[key] }
            if node == nil { return nil }
        }
        return node
    }

    /// Depth-first collection of the values stored under `key`, without descending into matches or `skipping` keys.
    /// Tolerant of YouTube's constantly reshuffled response layouts.
    public func descendants(named key: String, skipping: Set<String> = [], maxDepth: Int = 40) -> [JSONValue] {
        var out: [JSONValue] = []
        func walk(_ node: JSONValue, _ depth: Int) {
            guard depth < maxDepth else { return }
            switch node {
            case .object(let o):
                for (k, v) in o.sorted(by: { $0.key < $1.key }) where !skipping.contains(k) {
                    if k == key { out.append(v) } else { walk(v, depth + 1) }
                }
            case .array(let a):
                for v in a { walk(v, depth + 1) }
            default: break
            }
        }
        walk(self, 0)
        return out
    }

    /// Like `descendants(named:)` but for several keys at once, preserving document order across the keys.
    public func descendants(namedAny keys: Set<String>, skipping: Set<String> = [], maxDepth: Int = 40) -> [(key: String, value: JSONValue)] {
        var out: [(key: String, value: JSONValue)] = []
        func walk(_ node: JSONValue, _ depth: Int) {
            guard depth < maxDepth else { return }
            switch node {
            case .object(let o):
                for (k, v) in o.sorted(by: { $0.key < $1.key }) where !skipping.contains(k) {
                    if keys.contains(k) { out.append((k, v)) } else { walk(v, depth + 1) }
                }
            case .array(let a):
                for v in a { walk(v, depth + 1) }
            default: break
            }
        }
        walk(self, 0)
        return out
    }
}
