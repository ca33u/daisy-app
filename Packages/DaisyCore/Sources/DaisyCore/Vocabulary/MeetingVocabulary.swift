//
//  MeetingVocabulary.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/MeetingVocabulary.swift (macOS Daisy
//  1.0.7.72, 2026-09-19). Logic verbatim; `DictationDictionary
//  .applyCounting` → `DictationRules.applyCounting` (the pure copy in
//  this package).
//
//  The user's vocabulary, applied to meetings: their own replacement
//  rules plus the built-in transliterated-brand table, run over the
//  finished segments. Deterministic text replacement, one segment at a
//  time — it cannot merge, split, drop or reorder anything, which is
//  what makes it safe to run unattended over a transcript nobody is
//  going to re-read.
//

import Foundation
import os

public nonisolated enum MeetingVocabulary {
    private static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "MeetingVocabulary")

    /// What one pass changed, for the log and the fixes widget.
    public struct Result: Sendable {
        /// New text keyed by segment id — changed segments only.
        public let replacements: [UUID: String]
        /// Replacements from the user's own rules.
        public let dictionaryFixes: Int
        /// Replacements from the built-in brand table.
        public let brandFixes: Int

        public var isEmpty: Bool { replacements.isEmpty }

        public static let empty = Result(replacements: [:], dictionaryFixes: 0, brandFixes: 0)
    }

    /// Apply the user's rules and (when enabled) the brand table to
    /// every segment. The user's rules go first and win, then the
    /// built-in table fills gaps while skipping any brand the user has
    /// their own rule for.
    public static func corrections(
        for segments: [TranscriptSegment],
        rules: [DictationReplacement],
        applyBrandTable: Bool
    ) -> Result {
        let triggers = Set(rules.map { $0.from.lowercased() })
        var replacements: [UUID: String] = [:]
        var dictionaryFixes = 0
        var brandFixes = 0

        for segment in segments {
            let original = segment.text
            guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            var text = original
            let applied = DictationRules.applyCounting(to: text, rules: rules)
            text = applied.text
            dictionaryFixes += applied.fixes

            if applyBrandTable {
                let brand = BrandCorrections.apply(to: text, userTriggers: triggers)
                text = brand.text
                brandFixes += brand.fixes
            }

            if text != original { replacements[segment.id] = text }
        }

        if !replacements.isEmpty {
            log.info("Meeting vocabulary: \(replacements.count, privacy: .public) segment(s) corrected (rules=\(dictionaryFixes, privacy: .public), brands=\(brandFixes, privacy: .public))")
        }
        return Result(
            replacements: replacements,
            dictionaryFixes: dictionaryFixes,
            brandFixes: brandFixes
        )
    }
}
