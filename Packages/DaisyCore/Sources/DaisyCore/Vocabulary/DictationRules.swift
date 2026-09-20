//
//  DictationRules.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/DictationDictionary.swift (macOS Daisy
//  1.0.7.72, 2026-09-19) — ONLY the value type `DictationReplacement`
//  and the pure text functions `applyCounting` / `replaceCounting`.
//  The Mac `DictationDictionary` store (UserDefaults, SwiftUI editor,
//  Whisper bias terms) is not ported (phase Ф5); `MeetingVocabulary`
//  needs just this much to apply rules to a transcript.
//

import Foundation

/// One vocabulary entry: a `.term` you teach Daisy, or a `.correction`
/// rule. Plain Sendable value type.
public nonisolated struct DictationReplacement: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case correction
        case term
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, from, to, caseSensitive
    }

    public var id = UUID()
    public var kind: Kind = .correction
    /// The (mis)heard text to look for. Matched on word boundaries.
    /// Correction-only — empty/ignored for a `.term`.
    public var from: String = ""
    /// Correction: what to substitute. Term: the canonical word itself.
    public var to: String = ""
    /// When false (default), matching ignores case. Always treated as
    /// false for a `.term`.
    public var caseSensitive: Bool = false

    public init(
        id: UUID = UUID(),
        kind: Kind = .correction,
        from: String = "",
        to: String = "",
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.caseSensitive = caseSensitive
    }

    /// Tolerant decode — a dictionary written by an older build has no
    /// `kind` key; every row was a correction.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .correction
        self.from = (try? c.decode(String.self, forKey: .from)) ?? ""
        self.to = (try? c.decode(String.self, forKey: .to)) ?? ""
        self.caseSensitive = (try? c.decode(Bool.self, forKey: .caseSensitive)) ?? false
    }
}

/// The pure half of the Mac `DictationDictionary`: apply rules to text.
public nonisolated enum DictationRules {
    /// Apply every rule, longest needle first (stable against stored
    /// order for equal lengths). Returns the new text and how many
    /// occurrences actually changed.
    public static func applyCounting(
        to text: String,
        rules replacements: [DictationReplacement]
    ) -> (text: String, fixes: Int) {
        guard !text.isEmpty, !replacements.isEmpty else { return (text, 0) }

        struct Effective {
            let from: String
            let to: String
            let caseSensitive: Bool
            let order: Int
        }
        let effective: [Effective] = replacements.enumerated().map { offset, rule in
            switch rule.kind {
            case .correction:
                return Effective(from: rule.from, to: rule.to, caseSensitive: rule.caseSensitive, order: offset)
            case .term:
                return Effective(from: rule.to, to: rule.to, caseSensitive: false, order: offset)
            }
        }
        let ordered = effective.sorted { lhs, rhs in
            if lhs.from.count != rhs.from.count {
                return lhs.from.count > rhs.from.count
            }
            return lhs.order < rhs.order
        }

        var result = text
        var fixes = 0
        for rule in ordered {
            let needle = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            let (replaced, made) = replaceCounting(
                in: result, from: needle, with: rule.to, caseSensitive: rule.caseSensitive
            )
            result = replaced
            fixes += made
        }
        return (result, fixes)
    }

    /// Single-rule word-boundary replacement + a count of matches whose
    /// text actually CHANGED. `\b` is asserted only on a side that ends
    /// in a word character, so symbol-y rules behave like a literal
    /// substring replace while alphanumeric rules stay whole-word.
    public static func replaceCounting(
        in text: String,
        from: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> (text: String, fixes: Int) {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        let leadingBoundary = (from.first.map(isWordCharacter) ?? false) ? "\\b" : ""
        let trailingBoundary = (from.last.map(isWordCharacter) ?? false) ? "\\b" : ""
        let pattern = leadingBoundary + escaped + trailingBoundary

        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return (text, 0)
        }

        let range = NSRange(text.startIndex..., in: text)
        var fixes = 0
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            if String(text[r]) != replacement { fixes += 1 }
        }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        let out = regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: template
        )
        return (out, fixes)
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            if !(CharacterSet.alphanumerics.contains(scalar) || scalar == "_") {
                return false
            }
        }
        return !c.unicodeScalars.isEmpty
    }
}
