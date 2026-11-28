// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SpeakerNameMatching.swift
//  Daisy
//
//  Deciding whether two written forms of a name are the same person.
//  "Priya" and "Priya Raman"; "PriyaRaman" and "Priya Raman"; "AJ" and
//  "A J". Used wherever a name from one source has to be reconciled
//  with a name from another — a proposal against the calendar roster,
//  a calendar attendee against a saved speaker profile.
//
//  The rules are deliberately one-directional and deliberately timid,
//  because the two failure modes are not symmetric:
//
//    • Failing to merge costs the user one manual rename. Annoying.
//    • Merging wrongly puts a real person's name on someone else's
//      words, in a transcript that flows into the summary, the
//      follow-up draft, and anything auto-sent. That is not annoying,
//      it is a false record.
//
//  So: the fuller written form always wins, a short form never absorbs
//  a long one, spaceless forms only match when their parts are long
//  enough to not be initials, and ANY ambiguity resolves to "no match"
//  rather than to a best guess.
//

import Foundation

nonisolated enum SpeakerNameMatching {
    /// Shortest a name part may be for the spaceless form to be
    /// trusted. "AJ" ↔ "A J" is initials and must not merge; "PriyaRaman"
    /// ↔ "Priya Raman" is one person writing their name two ways.
    static let minimumPartLengthForSpacelessMatch = 3

    /// Resolve `candidate` to its canonical spelling from `roster`, or
    /// nil when it doesn't match exactly one entry.
    ///
    /// Tiers are tried strongest-first and do NOT fall through: if a
    /// tier finds two matches, that's ambiguity and the answer is nil —
    /// dropping to a weaker tier there would be picking a winner by
    /// technicality.
    ///
    ///   1. Same name, allowing for case and spacing.
    ///   2. Same name with the spaces removed, when every part of the
    ///      spaced form is at least `minimumPartLengthForSpacelessMatch`
    ///      characters. ("priyaraman" → "Priya Raman", but not
    ///      "aj" → "A J".)
    ///   3. A bare given name that begins exactly one roster entry.
    ///      People say first names in meetings; this is the tier that
    ///      earns its keep.
    ///
    /// The return value is always the ROSTER's spelling, never the
    /// candidate's. That is the one-way rule: a short form resolves up
    /// to the full name, and a full name is never shortened to match a
    /// stub. A candidate of "Priya Raman" against a roster holding only
    /// "Priya" is no match at all — the roster entry is not established
    /// enough to absorb the longer form.
    static func resolve(_ candidate: String, in roster: [String]) -> String? {
        guard let needle = normalize(candidate) else { return nil }

        switch match(in: roster, where: { normalize($0) == needle }) {
        case .one(let entry): return entry
        case .ambiguous: return nil
        case .none: break
        }

        let needleSpaceless = despaced(needle)
        switch match(in: roster, where: { entry in
            guard let normalized = normalize(entry) else { return false }
            // Both sides must be safe to despace: a two-letter part on
            // either side means we're looking at initials.
            guard spacelessMatchAllowed(normalized), spacelessMatchAllowed(needle) else { return false }
            return despaced(normalized) == needleSpaceless
        }) {
        case .one(let entry): return entry
        case .ambiguous: return nil
        case .none: break
        }

        // Given-name tier. Only a SINGLE-token candidate qualifies —
        // "Priya Raman from Acme" is not a given name, and treating it
        // as a prefix would let embellishment through. The token also
        // has to be long enough to be a name rather than an initial,
        // for the same reason the spaceless tier has that rule.
        guard !needle.contains(" "),
              needle.count >= minimumPartLengthForSpacelessMatch else { return nil }
        if case .one(let entry) = match(in: roster, where: { entry in
            guard let normalized = normalize(entry) else { return false }
            return normalized.hasPrefix(needle + " ")
        }) {
            return entry
        }
        return nil
    }

    // MARK: - Internals

    /// Outcome of scanning the roster with one tier's predicate.
    /// Ambiguity has to be its OWN case rather than collapsing into
    /// "no match": a tier that found two answers must stop the whole
    /// resolution, not hand the question down to a weaker tier that
    /// might confidently return a third person.
    private enum TierMatch {
        case none
        case one(String)
        case ambiguous
    }

    private static func match(
        in roster: [String],
        where predicate: (String) -> Bool
    ) -> TierMatch {
        var found: String? = nil
        for entry in roster where predicate(entry) {
            // Two entries that are themselves the same name (the roster
            // listing "Priya Raman" twice with different spacing) are
            // not ambiguity — they're a duplicate.
            if let found, normalize(found) != normalize(entry) { return .ambiguous }
            if found == nil { found = entry }
        }
        return found.map { TierMatch.one($0) } ?? .none
    }

    /// True when `a` and `b` name the same person under these rules,
    /// judged against each other rather than against a roster.
    static func sameName(_ a: String, _ b: String) -> Bool {
        resolve(a, in: [b]) != nil || resolve(b, in: [a]) != nil
    }

    /// Case-folded, trimmed, inner whitespace collapsed to single
    /// spaces. Nil for anything with no content.
    static func normalize(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func despaced(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: " ", with: "")
    }

    /// True when every whitespace-separated part is long enough that
    /// running them together can't be initials. A single-token name is
    /// trivially fine — there's nothing to run together.
    private static func spacelessMatchAllowed(_ normalized: String) -> Bool {
        normalized
            .split(separator: " ")
            .allSatisfy { $0.count >= minimumPartLengthForSpacelessMatch }
    }
}
