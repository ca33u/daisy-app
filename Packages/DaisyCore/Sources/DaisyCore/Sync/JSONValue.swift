//
//  JSONValue.swift
//  DaisyCore
//
//  backlog 10 J-1, the rule from backlog 9: **new fields are optional on
//  read, unknown fields are kept on write.** Two versions of Daisy share
//  the same state files and the same key-value store; a newer one must
//  never lose a field because an older one rewrote the file. Every
//  shared structure carries an `extra` bag: what it did not understand
//  goes back out untouched.
//

import Foundation

public nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not JSON")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// A coding key made from any string — for reading the keys a struct
/// does not declare and writing them back.
public nonisolated struct AnyCodingKey: CodingKey, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ string: String) { stringValue = string }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

nonisolated extension KeyedDecodingContainer where K == AnyCodingKey {
    /// Everything in the container except `known`.
    public func extras(except known: Set<String>) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) { out[key.stringValue] = value }
        }
        return out
    }
}

nonisolated extension KeyedEncodingContainer where K == AnyCodingKey {
    public mutating func encode(extras: [String: JSONValue]) throws {
        for (key, value) in extras { try encode(value, forKey: AnyCodingKey(key)) }
    }
}
