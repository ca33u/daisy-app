//
//  LenientJSON.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/LenientJSON.swift (03.11.2026), as this
//  CloudSummaryDTO is. Decoding helpers for what a model writes, as
//  `CloudSummaryDTO` reads it: any of several key names, a list that
//  keeps its good elements when one is broken, and a log line saying
//  where. A whole 48-minute summary
//  was lost three times running to one section or bullet that lacked a
//  field (log report 03.11.2026: «JSON schema mismatch (… missing)»).
//

import Foundation
import os

nonisolated enum LenientJSON {
    static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Summarizer")

    /// A key by any name, for reading aliases.
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    /// The first of `names` (in that order, case ignored) that holds a
    /// non-blank string, else the first that holds a blank one. A null
    /// counts as absent; any other value as absent and logged.
    static func string(_ container: KeyedDecodingContainer<Key>, _ names: [String]) -> String? {
        var blank: String?
        for key in keys(container, names) {
            guard let value = readable(String.self, container, key, "a string") else { continue }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            blank = blank ?? value
        }
        return blank
    }

    /// The first of `names` (in that order, case ignored) that holds a
    /// non-empty array, else the first empty one, with every element that
    /// fails to decode left out (and logged).
    static func list<Element: Decodable>(_ container: KeyedDecodingContainer<Key>, _ names: [String]) -> [Element]? {
        var empty: [Element]?
        for key in keys(container, names) {
            guard let value = readable(LossyList<Element>.self, container, key, "a list") else { continue }
            if !value.elements.isEmpty { return value.elements }
            empty = empty ?? value.elements
        }
        return empty
    }

    /// The keys present that answer to `names`, in the order of `names`.
    private static func keys(_ container: KeyedDecodingContainer<Key>, _ names: [String]) -> [Key] {
        let present = container.allKeys
        return names.flatMap { name in
            present.filter { $0.stringValue.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// The value under `key`; nil for a null, and nil with a log line for
    /// a value of another type — the line the 03.11 report didn't have.
    private static func readable<Value: Decodable>(_ type: Value.Type, _ container: KeyedDecodingContainer<Key>,
                                                   _ key: Key, _ expected: String) -> Value? {
        if (try? container.decodeNil(forKey: key)) == true { return nil }
        do {
            return try container.decode(Value.self, forKey: key)
        } catch {
            log.error("Summary JSON: \(path(container.codingPath + [key]), privacy: .public) is not \(expected, privacy: .public) — read as absent")
            return nil
        }
    }

    /// `sections[2].bullets[0]` — positions and key names only, never a
    /// value, so it is safe in a log report.
    static func path(_ codingPath: [CodingKey]) -> String {
        let joined = codingPath.reduce(into: "") { out, key in
            if let index = key.intValue { out += "[\(index)]" } else { out += out.isEmpty ? key.stringValue : ".\(key.stringValue)" }
        }
        return joined.isEmpty ? "the top level" : joined
    }

    /// What went wrong and where, without the model's text.
    static func reason(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .typeMismatch(let type, let context):
            return "\(path(context.codingPath)) is not \(type == String.self ? "a string" : "the expected type")"
        case .valueNotFound(_, let context):
            return "\(path(context.codingPath)) is null"
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON" : "\(path(context.codingPath)) is not readable"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// An array that keeps going past an element it can't read.
    struct LossyList<Element: Decodable>: Decodable {
        let elements: [Element]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var elements: [Element] = []
            while !container.isAtEnd {
                let index = container.currentIndex
                do {
                    elements.append(try container.decode(Element.self))
                } catch {
                    LenientJSON.log.error("Summary JSON: left out \(LenientJSON.path(decoder.codingPath), privacy: .public)[\(index, privacy: .public)] — \(LenientJSON.reason(error), privacy: .public)")
                    // A failed decode doesn't move the cursor; this does.
                    _ = try? container.decode(Skip.self)
                    if container.currentIndex == index { break }
                }
            }
            self.elements = elements
        }
    }

    /// Reads any value and keeps nothing.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
