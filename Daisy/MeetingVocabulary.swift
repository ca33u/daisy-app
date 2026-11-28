// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingVocabulary.swift
//  Daisy
//
//  The user's vocabulary, applied to meetings.
//
//  Dictation has had this since 1.0.5: their own replacement rules
//  ("клод" → "Claude") plus the built-in transliterated-brand table
//  ("фигма" → Figma) run over the text before it is pasted. Meetings
//  got neither, so the same word came out right when dictated and
//  wrong when recorded — the single most reported inconsistency in the
//  vocabulary feature.
//
//  Three layers now cover a meeting, weakest evidence last:
//
//    1. Decoder bias — the vocabulary is fed to Whisper's prompt on the
//       final pass, so it is more likely to hear the term correctly in
//       the first place (`WhisperEngine`, wired from `finalizePostStop`).
//    2. This module — deterministic text replacement over the finished
//       segments. Exact, auditable, and the only route that works for
//       Parakeet, which has no prompt support at all.
//    3. `TranscriptPolisher` — the LLM pass, which catches what neither
//       rule nor bias did.
//
//  Layer 2 runs on segment TEXT only, one segment at a time. It cannot
//  merge, split, drop or reorder anything, which is what makes it safe
//  to run unattended over a transcript nobody is going to re-read.
//

import Foundation
import os

nonisolated enum MeetingVocabulary {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "MeetingVocabulary")

    /// What one pass changed, for the log and the fixes widget.
    struct Result {
        /// New text keyed by segment id — changed segments only, so the
        /// caller can apply it as a patch.
        let replacements: [UUID: String]
        /// Replacements from the user's own rules.
        let dictionaryFixes: Int
        /// Replacements from the built-in brand table.
        let brandFixes: Int

        var isEmpty: Bool { replacements.isEmpty }

        static let empty = Result(replacements: [:], dictionaryFixes: 0, brandFixes: 0)
    }

    /// Apply the user's rules and (when enabled) the brand table to
    /// every segment.
    ///
    /// Order matches the dictation path exactly, and for the same
    /// reason: the user's rules go first and win, then the built-in
    /// table fills gaps while skipping any brand the user has their own
    /// rule for. Two paths producing different text for the same
    /// sentence is a bug report waiting to happen.
    static func corrections(
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
            let applied = DictationDictionary.applyCounting(to: text, rules: rules)
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
