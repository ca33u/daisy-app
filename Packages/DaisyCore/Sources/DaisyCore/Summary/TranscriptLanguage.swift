//
//  TranscriptLanguage.swift
//  DaisyCore
//
//  The phone's transcriber (Parakeet) does not report a language, so
//  the summary prompt gets no `detected_locale` hint and a cloud model
//  happily answers a Russian meeting in English (seen on the first
//  on-device run, 2026-09-19). Script is enough to fix the common case:
//  a Cyrillic-dominant transcript is Russian for Egor's purposes.
//  Latin text stays unhinted — the prompt then follows the transcript's
//  own language, which is right for English, German, Spanish alike.
//

import Foundation

public nonisolated enum TranscriptLanguage {
    /// "ru" when at least 40% of the letters are Cyrillic; nil otherwise.
    public static func guess(_ text: String) -> String? {
        var cyrillic = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 }
        }
        guard letters >= 20 else { return nil }
        return Double(cyrillic) / Double(letters) >= 0.4 ? "ru" : nil
    }
}
