//
//  SpeakerMapping.swift
//  DaisyCore
//
//  §3.2: the body keeps canonical `Remote A` labels; `daisy_speaker_map`
//  is applied at render time — one pass with a lookup (never a chain of
//  find-and-replace), aliases (`B: "Remote A"`) resolved exactly one
//  hop. `revert` is the inverse for an editor that showed names and
//  must write labels back: a name that maps to several labels goes to
//  the first in label order, which is the only honest choice without
//  a new field.
//

import Foundation

public nonisolated enum SpeakerMapping {
    private static let pattern = try! NSRegularExpression(pattern: #"\bRemote\s+([A-Z])\b"#)

    /// The display name of a label after one hop of aliasing; nil when
    /// the map says nothing about it.
    public static func displayName(for label: String, in map: [String: String]) -> String? {
        guard let value = map[label], !value.isEmpty else { return nil }
        if let alias = aliasedLabel(value) {
            if let primary = map[alias], !primary.isEmpty, aliasedLabel(primary) == nil { return primary }
            return "Remote \(alias)"
        }
        return value
    }

    /// `Remote X` → `X`, anything else → nil.
    public static func aliasedLabel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Remote ") else { return nil }
        let rest = trimmed.dropFirst("Remote ".count).trimmingCharacters(in: .whitespaces)
        guard rest.count == 1, let c = rest.first, c.isUppercase, c.isLetter else { return nil }
        return String(c)
    }

    /// Body with names in place of labels.
    public static func apply(_ map: [String: String], to text: String) -> String {
        guard !map.isEmpty else { return text }
        return replace(in: text) { label in displayName(for: label, in: map) }
    }

    /// Edited text with labels back in place of names — for a writer.
    public static func revert(_ map: [String: String], in text: String) -> String {
        guard !map.isEmpty else { return text }
        var byName: [String: String] = [:]
        for label in map.keys.sorted() {
            if let name = displayName(for: label, in: map), byName[name] == nil, aliasedLabel(name) == nil {
                byName[name] = label
            }
        }
        guard !byName.isEmpty else { return text }
        // Only the speaker slot of a segment line: `**[m:ss · Name]**`.
        let slot = try! NSRegularExpression(pattern: #"(\*\*\[[0-9:]+ · )([^\]]+)(\]\*\*)"#)
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in slot.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 2))
            let label = byName[name].map { "Remote \($0)" } ?? name
            out += ns.substring(with: match.range(at: 1)) + label + ns.substring(with: match.range(at: 3))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func replace(in text: String, _ lookup: (String) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1))
            guard let name = lookup(label) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += name
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
