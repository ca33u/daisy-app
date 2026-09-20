//
//  TranscriptLanguage.swift
//  DaisyCore
//
//  Fallback for a transcript without `detected_locale`: sessions from
//  the Parakeet era (it reported no language, and a cloud model then
//  happily answered a Russian meeting in English — first on-device run,
//  2026-09-19). Whisper (backlog 6 F-1) writes `detected_locale`
//  itself, so this only runs for old files. Script is enough for the
//  common case: a Cyrillic-dominant transcript is Russian for Egor's
//  purposes. Latin text stays unhinted — the prompt then follows the
//  transcript's own language, which is right for English, German,
//  Spanish alike.
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
