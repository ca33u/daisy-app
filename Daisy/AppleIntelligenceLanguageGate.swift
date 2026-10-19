//
//  AppleIntelligenceLanguageGate.swift
//  Daisy
//
//  Which language Apple Intelligence will be asked to write in, and what
//  to say when it can't (backlog 32 A-3, 19.10.2026).
//
//  A user with Apple Intelligence and Russian meetings got no summary and
//  no polish for two meetings, and the only trace was a log line — the
//  detail view and Settings looked as if nothing had happened. The
//  decisions here are pure so they can be tested without the framework:
//  the live `SystemLanguageModel.supportsLocale` check comes in as a
//  closure.
//

import Foundation

nonisolated enum AppleIntelligenceLanguageGate {
    /// Two-letter code of the language the person reads Daisy in: the
    /// Settings → Language override when there is one, else macOS's first
    /// preferred language. `nil` when neither says anything.
    static func interfaceLanguage(
        override: String?,
        preferred: [String] = Locale.preferredLanguages
    ) -> String? {
        if let override, override != "system", !override.isEmpty {
            return code(of: override)
        }
        return preferred.first.flatMap(code(of:))
    }

    /// The language a Settings warning is due for, or `nil` when none is.
    ///
    /// Only Apple Intelligence has a language it can't write. An explicit
    /// summary language has its own warning under its picker, so this
    /// one covers "Auto": the meeting arrives in the pinned transcription
    /// language when there is one — a supported pin means the summaries
    /// will be written, whatever the interface says — and otherwise most
    /// likely in the language the person runs Daisy in.
    static func languageToWarnAbout(
        provider: SummaryProviderKind,
        summaryLanguage: String,
        interfaceLanguage: String?,
        transcriptionLanguage: String,
        supports: (String) -> Bool
    ) -> String? {
        guard provider == .appleIntelligence else { return nil }
        guard summaryLanguage.isEmpty || summaryLanguage == SummaryLanguage.auto.id else { return nil }
        if let pinned = code(of: transcriptionLanguage), pinned != "auto" {
            return supports(pinned) ? nil : pinned
        }
        guard let interface = interfaceLanguage, !supports(interface) else { return nil }
        return interface
    }

    /// "Apple Intelligence doesn't write in Russian yet." — the languages
    /// Daisy's users actually hit get a hand-written sentence; any other
    /// is named through the locale.
    static func cannotWritePhrase(provider: String, languageCode: String?) -> String {
        switch languageCode.flatMap(code(of:)) {
        case "ru": return String(localized: "\(provider) doesn't write in Russian yet.")
        case "uk": return String(localized: "\(provider) doesn't write in Ukrainian yet.")
        case "be": return String(localized: "\(provider) doesn't write in Belarusian yet.")
        case "pl": return String(localized: "\(provider) doesn't write in Polish yet.")
        case let code?:
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return String(localized: "\(provider) doesn't write in \(name) yet.")
        case nil:
            return String(localized: "\(provider) doesn't write in this language yet.")
        }
    }

    /// The whole Settings warning for `languageToWarnAbout`'s answer.
    static func settingsWarning(provider: String, languageCode: String) -> String {
        cannotWritePhrase(provider: provider, languageCode: languageCode)
            + " "
            + String(localized: "Meetings in that language get no summary — choose another provider above.")
    }

    /// "ru-RU" → "ru", "auto" → "auto", "" → nil.
    private static func code(of identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "auto" { return "auto" }
        return Locale(identifier: trimmed).language.languageCode?.identifier.lowercased()
            ?? String(trimmed.prefix(2)).lowercased()
    }
}
