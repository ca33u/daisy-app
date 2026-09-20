//
//  LanguageDetector.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/LanguageDetector.swift (macOS Daisy
//  1.0.7.72, 2026-09-20), `detect` and its gates only. backlog 6 F-1:
//  the phone writes `detected_locale` the same way the Mac does — from
//  the TEXT, through `NLLanguageRecognizer` — not from Whisper's own
//  per-window language token, which said `en` for a plainly Russian
//  recording on the first on-device run (2026-09-20 11:24). Whisper's
//  verdict stays as the fallback for text too short to judge.
//
//  The detector is intentionally conservative: only codes the summary
//  prompt has scaffolding for, a non-trivial sample and a minimum
//  confidence; below threshold it returns nil and the model decides.
//

import Foundation
import NaturalLanguage

public nonisolated enum LanguageDetector {
    /// ISO 639-1 code (`ru`, `en`, …) for the dominant language in
    /// `text`, or nil if the input is too short, confidence too low, or
    /// the language isn't one the summary prompt knows how to handle.
    public static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Below ~16 chars NLLanguageRecognizer guesses from a couple of
        // glyphs and is unreliable.
        guard trimmed.count >= 16 else { return nil }
        // 1500 chars disambiguate even mixed-language transcripts.
        let sample = String(trimmed.prefix(1500))

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let ranked = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        // Below 0.55 the recognizer is flipping a coin between two
        // similar languages — "no hint" beats "wrong hint".
        guard let top = ranked.first, top.value >= 0.55 else { return nil }
        let code = top.key.rawValue
        guard supportedSummaryCodes.contains(code) else { return nil }
        return code
    }

    /// Mirrors the explicit branches in the Mac's
    /// `SummaryPrompt.systemInstructions(localeHint:)`.
    private static let supportedSummaryCodes: Set<String> = [
        "en", "ru", "uk", "pl", "es", "fr", "de", "it", "pt", "ja", "ko", "zh",
    ]
}
