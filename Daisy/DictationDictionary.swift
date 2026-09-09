//
//  DictationDictionary.swift
//  Daisy
//
//  User-defined custom-vocabulary substitutions applied to dictation
//  output just before it's pasted. The speech model reliably mishears
//  proper nouns, brands, and jargon ("claude" → should be "Claude",
//  "sazzi" → "Sazzi", "daisy app" → "Daisy"); this store lets the user
//  curate a small replacement table that fixes those after transcription
//  but before the text lands in their active field.
//
//  Why a plain ordered list (not a dict): order is user-meaningful.
//  Two rules can target overlapping text ("daisy" and "daisy app"), and
//  the user controls precedence by reordering. `apply(to:)` additionally
//  sorts by `from` length descending at match time so a longer phrase
//  always wins over a shorter prefix regardless of row order — but the
//  stored order is preserved for the editor and for ties.
//
//  Matching is word-boundary anchored so "cat" → "dog" never corrupts
//  "category". Case-insensitive by default (most fixes are casing fixes,
//  and the user dictates lower-case); per-rule `caseSensitive` opt-in for
//  the rare case where the source casing matters.
//
//  Persistence: a single JSON blob in UserDefaults under
//  `daisy.dictationDictionary`. The table is tiny (a handful of short
//  strings) so there's no reason to spread it across files the way
//  `SpeakerProfileStore` does.
//
//  @MainActor: the store is read on the MainActor-isolated dictation
//  paste path (`DictationPaste.handle`) and mutated from the Settings
//  editor (also MainActor). Keeping it MainActor means `apply(to:)` is a
//  plain same-actor call with no hop or snapshot at the call site.
//

import Foundation
import Observation
import os
import SwiftUI  // for Array.move(fromOffsets:toOffset:) used in move(from:to:)

/// One vocabulary entry. Two flavours (Wispr-Flow's "Add to vocabulary"
/// model): a `.term` you teach Daisy, or a `.correction` rule.
/// `Identifiable` so SwiftUI's `ForEach`/`.sheet(item:)` can track rows;
/// `Equatable` so the editor can diff cheaply.
// `nonisolated` — constructed from the nonisolated `parseImport` (bulk
// import) as well as on the main actor; plain Sendable value type, same
// pattern as `CloudSummaryDTO`.
nonisolated struct DictationReplacement: Codable, Identifiable, Equatable {
    /// What kind of entry this is.
    ///   • `.correction` — replace `from` (the misheard text) with `to`.
    ///     The historical behaviour; every row a pre-1.0.7.20 build saved
    ///     is one of these (see the tolerant decoder below).
    ///   • `.term` — a single custom word Daisy should know. `to` holds
    ///     the canonical spelling/casing; `from` is unused. A term enforces
    ///     its canonical casing on output (post-process, both engines) and,
    ///     on Whisper, biases recognition toward it via `promptTokens`.
    enum Kind: String, Codable, Equatable {
        case correction
        case term
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, from, to, caseSensitive
    }

    var id = UUID()
    var kind: Kind = .correction
    /// The (mis)heard text to look for. Matched on word boundaries.
    /// Correction-only — empty/ignored for a `.term`.
    var from: String = ""
    /// Correction: what to substitute. Term: the canonical word itself.
    var to: String = ""
    /// When false (default), matching ignores case ("claude", "Claude",
    /// "CLAUDE" all match). When true, only an exact-case occurrence of
    /// `from` is replaced. Always treated as false for a `.term` (a term
    /// is inherently a case-normalising rule).
    var caseSensitive: Bool = false

    init(
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

    /// Tolerant decode. A dictionary written by an older build has no
    /// `kind` key — every row was a correction. Defaulting the missing
    /// key (instead of letting `decode` throw) is what keeps the
    /// whole-array decode in `DictationDictionary.init` from failing and
    /// silently wiping the user's table on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .correction
        self.from = (try? c.decode(String.self, forKey: .from)) ?? ""
        self.to = (try? c.decode(String.self, forKey: .to)) ?? ""
        self.caseSensitive = (try? c.decode(Bool.self, forKey: .caseSensitive)) ?? false
    }
}

@MainActor
@Observable
final class DictationDictionary {
    static let shared = DictationDictionary()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationDictionary")

    /// UserDefaults key for the persisted JSON array of rules.
    private static let defaultsKey = "daisy.dictationDictionary"

    /// Ordered list of rules. Order is user-controlled (drag to reorder)
    /// and used as the tie-breaker when two rules have equal-length
    /// `from` strings. Observable so the editor re-renders on any
    /// add/edit/delete/move. Persisted on every mutation via `didSet`.
    private(set) var replacements: [DictationReplacement] {
        didSet { persist() }
    }

    private init() {
        // Restore from UserDefaults. A missing/!corrupt blob starts
        // empty rather than crashing — the table is non-critical and a
        // bad decode shouldn't take down dictation.
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([DictationReplacement].self, from: data) {
            replacements = decoded
        } else {
            replacements = []
        }
    }

    // MARK: - Mutation

    /// Append a fully-formed entry (built by the Add-vocabulary modal) and
    /// return its id. Entries whose effective needle is empty are harmless
    /// — `apply(to:)` skips them — so a half-filled entry never corrupts
    /// output.
    @discardableResult
    func add(_ replacement: DictationReplacement) -> UUID {
        replacements.append(replacement)
        return replacement.id
    }

    /// Replace a rule in place, matched by `id`. No-op if the id is
    /// unknown (e.g. the row was deleted in another code path between
    /// the editor reading it and committing the edit).
    func update(_ replacement: DictationReplacement) {
        guard let idx = replacements.firstIndex(where: { $0.id == replacement.id }) else { return }
        replacements[idx] = replacement
    }

    /// Remove a rule by value (matched on `id`).
    func remove(_ replacement: DictationReplacement) {
        replacements.removeAll { $0.id == replacement.id }
    }

    /// Reorder rules — thin wrapper over `Array.move` so the editor can
    /// bind `List`/`ForEach` `.onMove` straight to it.
    func move(from source: IndexSet, to destination: Int) {
        replacements.move(fromOffsets: source, toOffset: destination)
    }

    /// Bulk-append parsed entries in ONE mutation (a single `didSet`
    /// persist, not N). Skips exact duplicates already present
    /// (case-insensitive on kind + from + to) so re-importing the same
    /// list is idempotent. Returns how many were actually added.
    @discardableResult
    func importEntries(_ entries: [DictationReplacement]) -> Int {
        guard !entries.isEmpty else { return 0 }
        var working = replacements
        var added = 0
        for entry in entries {
            let dup = working.contains { existing in
                existing.kind == entry.kind
                    && existing.from.caseInsensitiveCompare(entry.from) == .orderedSame
                    && existing.to.caseInsensitiveCompare(entry.to) == .orderedSame
            }
            guard !dup else { continue }
            working.append(entry)
            added += 1
        }
        if added > 0 { replacements = working }  // one didSet → one persist
        return added
    }

    /// Parse pasted / imported text into entries. One entry per non-empty
    /// line; blank lines and `#` comments skipped. A line is a CORRECTION
    /// when it carries a separator (`=>`, `→`, tab, or comma) —
    /// `wrong <sep> right`; otherwise the whole line is a TERM (canonical
    /// spelling Daisy should preserve/bias toward).
    nonisolated static func parseImport(_ text: String) -> [DictationReplacement] {
        var out: [DictationReplacement] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let (lhs, rhs) = splitPair(line) {
                let from = lhs.trimmingCharacters(in: .whitespaces)
                let to = rhs.trimmingCharacters(in: .whitespaces)
                if !from.isEmpty, !to.isEmpty {
                    out.append(DictationReplacement(kind: .correction, from: from, to: to))
                }
            } else {
                out.append(DictationReplacement(kind: .term, from: "", to: line))
            }
        }
        return out
    }

    /// The vocabulary as the text `parseImport` reads back: one entry per
    /// line, corrections as `wrong => right`, terms bare. A comment header
    /// names the file; `#` lines are skipped on import. Terms and
    /// corrections come out in their list order so a re-import keeps it.
    nonisolated static func exportText(_ entries: [DictationReplacement]) -> String {
        var lines = [
            "# Daisy vocabulary — \(entries.count) entries",
            "# A bare line is a term; `wrong => right` is a correction.",
            "",
        ]
        for entry in entries {
            switch entry.kind {
            case .term:
                lines.append(entry.to)
            case .correction:
                lines.append("\(entry.from) => \(entry.to)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Split a line on the first correction separator, if any. Order:
    /// `=>` / `→` (explicit), then tab, then comma. Returns nil for a
    /// bare word/phrase (→ treated as a term).
    nonisolated private static func splitPair(_ line: String) -> (String, String)? {
        for sep in ["=>", "→"] {
            if let r = line.range(of: sep) {
                return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
            }
        }
        if let r = line.range(of: "\t") {
            return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
        }
        if let r = line.range(of: ",") {
            return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
        }
        return nil
    }

    // MARK: - Apply

    /// Run every rule against `text` and return the rewritten string.
    ///
    /// Guarantees:
    ///  - Rules whose `from` is empty (or whitespace-only) are skipped —
    ///    an empty pattern would otherwise match between every character.
    ///  - Matching is anchored to word boundaries (`\b…\b`), so "cat" →
    ///    "dog" leaves "category" untouched. `from` is regex-escaped, so
    ///    a rule like "C++" or "node.js" is matched literally, not as a
    ///    pattern.
    ///  - Case-insensitive unless the rule opts into `caseSensitive`.
    ///  - Longer `from` strings are applied first, so when "daisy" and
    ///    "daisy app" both exist the more specific phrase wins and the
    ///    shorter rule can't eat half of it first.
    ///  - Robust to arbitrary input: any rule whose regex fails to
    ///    compile is skipped rather than aborting the whole pass, and the
    ///    original text is returned unchanged if nothing matches.
    ///
    /// Called on the MainActor from `DictationPaste.handle(transcript:)`.
    func apply(to text: String) -> String {
        applyCounting(to: text).text
    }

    /// Like `apply(to:)`, but also reports how many replacements were
    /// actually MADE (a match that already read exactly as its target
    /// doesn't count — rewriting "Claude" to "Claude" fixed nothing).
    /// Feeds the "fixes made by Daisy" stat.
    func applyCounting(to text: String) -> (text: String, fixes: Int) {
        Self.applyCounting(to: text, rules: replacements)
    }

    /// The rule engine itself, over an explicit rule list.
    ///
    /// `nonisolated static` so callers that hold rules as plain data can
    /// use it without the singleton — `MeetingVocabulary` applies the
    /// same rules to a finished meeting transcript, and it must produce
    /// byte-identical output to the dictation path or the two surfaces
    /// disagree about the same sentence.
    nonisolated static func applyCounting(
        to text: String,
        rules replacements: [DictationReplacement]
    ) -> (text: String, fixes: Int) {
        guard !text.isEmpty, !replacements.isEmpty else { return (text, 0) }

        // Normalise each entry to an effective (needle → replacement) pair:
        //   • correction — `from → to` with the rule's own case-sensitivity.
        //   • term        — `to → to`, case-insensitive: the word is its own
        //     target, so any-case occurrence is rewritten to the canonical
        //     spelling/casing the user typed ("claude" → "Claude").
        // Then apply longest-needle-first, stable against the stored order
        // for equal lengths (so the user's chosen precedence decides ties).
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
            let (replaced, made) = Self.replaceCounting(
                in: result, from: needle, with: rule.to, caseSensitive: rule.caseSensitive
            )
            result = replaced
            fixes += made
        }
        return (result, fixes)
    }

    // MARK: - Whisper biasing

    /// Canonical spellings to bias the Whisper decoder toward (fed in as
    /// `DecodingOptions.promptTokens`). Returns every entry's `to` — the
    /// `.term` words AND each correction's target spelling, i.e. all the
    /// strings we WANT the model to produce — de-duplicated (case-insensitive),
    /// trimmed, empties dropped.
    ///
    /// Whisper-only: Parakeet (FluidAudio) has no equivalent hook, so for
    /// that engine a term contributes nothing here — but the casing
    /// normalisation in `apply(to:)` still fixes its output. Best-effort
    /// either way: biasing nudges recognition, it doesn't guarantee it, and
    /// `apply(to:)` runs regardless.
    func biasTerms() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for rule in replacements {
            let term = rule.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            if seen.insert(term.lowercased()).inserted {
                out.append(term)
            }
        }
        return out
    }

    /// Single-rule word-boundary replacement. Factored out (and
    /// `nonisolated static`) so it's trivially unit-testable and carries
    /// no actor or instance state.
    ///
    /// `\b` in ICU is a Unicode word boundary — it sits between a
    /// word-character (`\w`) and a non-word-character. For an alphabetic
    /// `from` this is exactly "whole word". For a `from` that starts or
    /// ends with a non-word character (e.g. "++" or a leading symbol) a
    /// `\b` on that side would never match the way the user expects, so
    /// we drop the boundary on whichever side is non-word and keep it on
    /// the word side. That makes symbol-y rules behave like a literal
    /// substring replace while alphanumeric rules stay whole-word.
    nonisolated static func replace(
        in text: String,
        from: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> String {
        replaceCounting(in: text, from: from, with: replacement, caseSensitive: caseSensitive).text
    }

    /// `replace` + a count of matches whose text actually CHANGED (an
    /// occurrence already spelled exactly like `replacement` isn't a fix).
    nonisolated static func replaceCounting(
        in text: String,
        from: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> (text: String, fixes: Int) {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        // Only assert a boundary on a side that ends in a word character;
        // a `\b` adjacent to punctuation/symbol would never fire.
        let leadingBoundary = (from.first.map(Self.isWordCharacter) ?? false) ? "\\b" : ""
        let trailingBoundary = (from.last.map(Self.isWordCharacter) ?? false) ? "\\b" : ""
        let pattern = leadingBoundary + escaped + trailingBoundary

        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            // Shouldn't happen (the user content is escaped), but if some
            // pathological input slips through, leave the text untouched
            // rather than throwing on the paste path.
            return (text, 0)
        }

        let range = NSRange(text.startIndex..., in: text)

        // Count matches whose current text differs from the target — only
        // those are real fixes.
        var fixes = 0
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            if String(text[r]) != replacement { fixes += 1 }
        }

        // Escape `$`/`\` in the replacement so user text containing them
        // isn't reinterpreted as a capture-group template by the regex
        // engine (e.g. a rule producing "$5" or a Windows path).
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        let out = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
        return (out, fixes)
    }

    /// True when `c` is a Unicode word character (letter, digit, or
    /// underscore) — i.e. a character `\w`/`\b` treats as part of a word.
    private nonisolated static func isWordCharacter(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            if !(CharacterSet.alphanumerics.contains(scalar) || scalar == "_") {
                return false
            }
        }
        return !c.unicodeScalars.isEmpty
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(replacements)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            log.error("Couldn't persist dictation dictionary: \(error.localizedDescription, privacy: .public)")
        }
    }
}
