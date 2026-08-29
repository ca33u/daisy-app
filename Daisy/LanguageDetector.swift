//
//  LanguageDetector.swift
//  Daisy
//
//  Thin wrapper around `NLLanguageRecognizer` (NaturalLanguage
//  framework) that sniffs the dominant language in a transcript blob.
//
//  Used as the fallback for summary localization in
//  `RecordingSession.localeHintForSummary` when both
//  `settings.summaryLanguage` and the transcription `localeIdentifier`
//  are set to "auto". Without this we'd hand `SummaryPrompt` a nil
//  hint, the prompt would say "the transcript's language (English if
//  mixed)", and Claude/GPT would default to English even on a clearly
//  Russian transcript (observed during QA on 2026-05-17).
//
//  The detector is intentionally conservative:
//   - It only returns codes for languages `SummaryPrompt` has
//     explicit scaffolding for. Returning a random ISO code the
//     prompt doesn't understand would just bias the model in a
//     direction we can't reason about.
//   - It requires a non-trivial sample and a minimum confidence
//     before answering. Below threshold it returns nil and lets the
//     model decide — better than picking the wrong language outright.
//

import Foundation
import NaturalLanguage

enum LanguageDetector {
    /// Returns an ISO 639-1 two-letter code (e.g. "ru", "en", "es")
    /// for the dominant language in `text`, or nil if the input is
    /// too short, confidence is too low, or the detected language
    /// isn't one `SummaryPrompt` knows how to localize for.
    ///
    /// `nonisolated` because callers include
    /// `RecordingSession.resolveSummaryLocaleHint` (itself nonisolated
    /// — fed by a background summary path). The body only touches
    /// NLLanguageRecognizer + a String literal set, no shared mutable
    /// state, so there's nothing for MainActor isolation to protect.
    /// Without this the Swift 6 default-MainActor module setting
    /// would propagate to `detect` and emit a synchronous-cross-actor
    /// warning at every call site.
    nonisolated static func detect(_ text: String) -> String? {
        detectDetailed(text)?.code
    }

    /// What `detect` found, plus the runner-up's confidence.
    nonisolated struct Verdict: Sendable, Equatable {
        let code: String
        let confidence: Double
        /// Confidence of the second-best hypothesis, 0 when there was
        /// none. A strong runner-up is the cheapest code-switching
        /// signal we have (`VoiceCorpusBucket.codeSwitchSamples`).
        let runnerUpConfidence: Double
    }

    /// Same gates as `detect` — this is where they actually live — but
    /// also reports how close the second hypothesis came. The voice
    /// corpus needs that; the summary-locale callers don't and keep
    /// using `detect`.
    nonisolated static func detectDetailed(_ text: String) -> Verdict? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Below ~16 chars NLLanguageRecognizer guesses based on a
        // couple of glyphs and is unreliable. Voice memos under that
        // threshold are noise anyway.
        guard trimmed.count >= 16 else { return nil }

        // 1500 chars is enough to disambiguate even mixed-language
        // transcripts; processing the entire transcript wastes
        // cycles without changing the verdict.
        let sample = String(trimmed.prefix(1500))

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)

        // Take top hypothesis and gate on confidence. Below 0.55 the
        // recognizer is essentially flipping a coin between two
        // similar languages and we prefer "no hint" over "wrong hint".
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let ranked = hypotheses.sorted { $0.value > $1.value }
        guard
            let top = ranked.first,
            top.value >= 0.55
        else { return nil }

        let code = top.key.rawValue
        guard supportedSummaryCodes.contains(code) else { return nil }
        return Verdict(
            code: code,
            confidence: top.value,
            runnerUpConfidence: ranked.dropFirst().first?.value ?? 0
        )
    }

    /// Mirrors the explicit branches in
    /// `SummaryPrompt.systemInstructions(localeHint:)`. "en" is
    /// included so a detected-English transcript short-circuits the
    /// chain in `localeHintForSummary` instead of falling through to
    /// another lookup (the prompt's default branch already produces
    /// English-or-mixed output for nil and "en" alike).
    ///
    /// `nonisolated` because `detect` (above) reads this set and is
    /// itself nonisolated. Plain String literal Set, no shared
    /// mutation — safe to read from any actor.
    nonisolated private static let supportedSummaryCodes: Set<String> = [
        "en", "ru", "uk", "pl", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"
    ]
}
