// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingVocabularyTests.swift
//  DaisyTests
//
//  Two things are being locked in here. That a meeting gets the same
//  vocabulary treatment dictation always got — same layers, same order,
//  same result for the same sentence. And that feeding the user's
//  vocabulary to Whisper's decoder prompt can't come back out as
//  speech: the prompt-echo filter and the term cap are what stand
//  between "bias the decoder" and "put the user's word list in the
//  transcript".
//

import Testing
import Foundation
@testable import Daisy

@Suite("Meeting vocabulary")
struct MeetingVocabularyTests {

    private func segment(_ text: String, at offset: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            text: text,
            isFinal: true
        )
    }

    /// Rules as plain data — no singleton, no UserDefaults.
    private func rules(_ pairs: [(String, String)]) -> [DictationReplacement] {
        pairs.map { DictationReplacement(from: $0.0, to: $0.1) }
    }

    // MARK: - Corrections

    @Test("A user rule fixes the same word in a meeting that it fixes in dictation")
    func corrections_appliesUserRules() {
        let one = segment("мы обсудили клод и его лимиты")
        let result = MeetingVocabulary.corrections(
            for: [one],
            rules: rules([("клод", "Claude")]),
            applyBrandTable: false
        )
        #expect(result.replacements[one.id] == "мы обсудили Claude и его лимиты")
        #expect(result.dictionaryFixes == 1)
    }

    @Test("The built-in brand table restores transliterated names")
    func corrections_appliesBrandTable() {
        let one = segment("макеты лежат в фигме, код в гитхабе")
        let result = MeetingVocabulary.corrections(
            for: [one],
            rules: rules([]),
            applyBrandTable: true
        )
        let text = result.replacements[one.id]
        #expect(text?.contains("Figma") == true)
        #expect(text?.contains("GitHub") == true)
        #expect(result.brandFixes == 2)
    }

    @Test("The brand table can be turned off without touching user rules")
    func corrections_brandTableIsOptional() {
        let one = segment("макеты лежат в фигме")
        let result = MeetingVocabulary.corrections(
            for: [one],
            rules: rules([]),
            applyBrandTable: false
        )
        #expect(result.isEmpty)
    }

    @Test("A user rule beats the built-in table for the same brand")
    func corrections_userRulesWin() {
        // The user calls it something else on purpose, and owning the
        // brand means the built-in table stands down for it entirely —
        // otherwise the two layers would fight over the same word.
        let one = segment("посмотри в фигма сегодня")
        let result = MeetingVocabulary.corrections(
            for: [one],
            rules: rules([("фигма", "Figma Design")]),
            applyBrandTable: true
        )
        #expect(result.replacements[one.id] == "посмотри в Figma Design сегодня")
    }

    @Test("A user rule that owns a brand suppresses the built-in table for its inflections too")
    func corrections_userRuleSuppressesBrandTableEvenWhenItDoesntMatch() {
        // Worth pinning because it's surprising: the user's rule is a
        // literal word-boundary match ("фигма"), so it does NOT fire on
        // the declined "фигме" — and because they own the brand, the
        // built-in table (which DOES handle Russian endings) stays out.
        // Net effect: the inflected form is left alone. This is exactly
        // what dictation does today, and matching it is the point of
        // this whole module — one behaviour, both surfaces.
        let one = segment("посмотри в фигме")
        let result = MeetingVocabulary.corrections(
            for: [one],
            rules: rules([("фигма", "Figma Design")]),
            applyBrandTable: true
        )
        #expect(result.isEmpty)

        // Without a competing user rule, the table handles the ending.
        let bare = segment("посмотри в фигме")
        let fallback = MeetingVocabulary.corrections(
            for: [bare], rules: rules([]), applyBrandTable: true
        )
        #expect(fallback.replacements[bare.id] == "посмотри в Figma")
    }

    @Test("Unchanged segments produce no patch entries")
    func corrections_returnsOnlyChanged() {
        let untouched = segment("обычная фраза без терминов")
        let fixed = segment("а тут клод")
        let result = MeetingVocabulary.corrections(
            for: [untouched, fixed],
            rules: rules([("клод", "Claude")]),
            applyBrandTable: false
        )
        #expect(result.replacements.count == 1)
        #expect(result.replacements[fixed.id] != nil)
    }

    @Test("Blank segments are skipped")
    func corrections_skipsBlankSegments() {
        let result = MeetingVocabulary.corrections(
            for: [segment("   "), segment("")],
            rules: rules([("клод", "Claude")]),
            applyBrandTable: true
        )
        #expect(result.isEmpty)
    }

    @Test("Corrections stay inside one segment — never merged, split or reordered")
    func corrections_areTextOnly() {
        let a = segment("первая про клод", at: 0)
        let b = segment("вторая про клод", at: 5)
        let result = MeetingVocabulary.corrections(
            for: [a, b],
            rules: rules([("клод", "Claude")]),
            applyBrandTable: false
        )
        // Two segments in, two independent replacements out, each
        // keyed to its own id.
        #expect(result.replacements.count == 2)
        #expect(result.replacements[a.id] == "первая про Claude")
        #expect(result.replacements[b.id] == "вторая про Claude")
    }

    // MARK: - Prompt echo

    /// The word-token form the engine compares in.
    private func terms(_ list: [String]) -> [[String]] {
        list.map { WhisperEngine.biasWordTokens($0) }
    }

    @Test("A run of the vocabulary list read back is dropped")
    func biasEcho_detectsPromptReadback() {
        // Whisper's documented `initial_prompt` failure: on a
        // low-information span it emits the prompt as if it were
        // speech. In dictation that's one bad paste; in a meeting it
        // lands mid-conversation attributed to whoever was talking.
        let list = terms(["Claude Code", "Figma", "GitHub", "Parakeet", "Notion"])
        #expect(WhisperEngine.looksLikeBiasEcho("Claude Code Figma GitHub", terms: list))
        #expect(WhisperEngine.looksLikeBiasEcho("Figma GitHub Parakeet.", terms: list))
        // A run starting mid-list still counts.
        #expect(WhisperEngine.looksLikeBiasEcho("GitHub, Parakeet, Notion", terms: list))
    }

    @Test("Saying your own vocabulary words is not an echo")
    func biasEcho_keepsRealSpeech() {
        let list = terms(["Мария Иванова", "техническое задание", "Claude Code",
                          "Kubernetes", "product-market fit"])
        // The case that made the first version of this filter dangerous:
        // one long term, alone, is just someone saying a name — and
        // deleting it from a meeting transcript is silent and permanent.
        #expect(!WhisperEngine.looksLikeBiasEcho("Мария Иванова.", terms: list))
        #expect(!WhisperEngine.looksLikeBiasEcho("Техническое задание!", terms: list))
        #expect(!WhisperEngine.looksLikeBiasEcho("product-market fit", terms: list))
        // Two adjacent terms is an ordinary standup sentence.
        #expect(!WhisperEngine.looksLikeBiasEcho("Claude Code Kubernetes", terms: list))
        // Terms embedded in real speech, in any arrangement.
        #expect(!WhisperEngine.looksLikeBiasEcho("Мария Иванова, привет", terms: list))
        #expect(!WhisperEngine.looksLikeBiasEcho("посмотри Claude Code и Kubernetes сегодня", terms: list))
    }

    @Test("A partial run must still account for the whole segment")
    func biasEcho_requiresTheRunToBeTheEntireSegment() {
        let list = terms(["Claude", "Figma", "GitHub", "Notion"])
        // Opens with three terms but keeps going — that's a sentence.
        #expect(!WhisperEngine.looksLikeBiasEcho("Claude Figma GitHub помогли нам вчера", terms: list))
        // A term inserted in the middle of the run breaks the order.
        #expect(!WhisperEngine.looksLikeBiasEcho("Claude Figma очень GitHub", terms: list))
    }

    @Test("Echo detection ignores case and punctuation")
    func biasEcho_normalizes() {
        let list = terms(["Claude", "Figma", "GitHub"])
        #expect(WhisperEngine.looksLikeBiasEcho("claude, figma, github!", terms: list))
        #expect(WhisperEngine.biasWordTokens("  Claude,  Figma! ") == ["claude", "figma"])
    }

    @Test("A vocabulary too short to form a run can't trip the filter at all")
    func biasEcho_needsEnoughTerms() {
        let list = terms(["Claude", "Figma"])
        #expect(!WhisperEngine.looksLikeBiasEcho("Claude Figma", terms: list))
        #expect(!WhisperEngine.looksLikeBiasEcho("Claude", terms: []))
    }

    // MARK: - Caps

    @Test("The bias prompt is capped well under Whisper's window")
    func bias_capsAreConservative() {
        // Whisper's decoder prompt window is ~224 tokens, and anything
        // past it displaces the audio context rather than being
        // politely ignored. A user who bulk-imported hundreds of rules
        // must not be able to crowd it out.
        #expect(WhisperEngine.maxBiasTerms <= 50)
        #expect(WhisperEngine.maxBiasPromptTokens <= 180)
    }
}
