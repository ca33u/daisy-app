//
//  SummaryFailureNote.swift
//  Daisy
//
//  Why a session has no summary, kept next to it (07.10.2026).
//
//  A user's summaries failed for hours — Apple Intelligence was off on
//  her Mac and doesn't write Russian — and the only trace was the log:
//  the meeting simply had no summary block, with nothing saying why or
//  what to change. The reason lived in `Summarizer.lastError`, in memory,
//  overwritten by the next call and gone at the next launch.
//
//  `.summary_failure.json` in the session folder, next to the
//  `.send_failures.json` auto-send writes: hidden, not synced, not read
//  by the Library parser. Written when a summary that should have come
//  didn't; removed when one is saved.
//

import Foundation
import os

/// What kept the summary from coming, when the fix is not "try again".
/// Carried from the provider's error through `Summarizer.lastFailureCause`
/// into the note, so the banner can offer the right button (19.10.2026).
nonisolated enum SummaryFailureCause: Codable, Equatable, Sendable {
    /// Apple Intelligence can't write this language (Russian among
    /// them); `languageCode` is nil when it refused without being asked
    /// for one. Trying again changes nothing — another provider does.
    case unsupportedLanguage(languageCode: String?)

    /// The cause behind a provider's error, or nil for the ordinary kind.
    static func of(_ error: any Error) -> SummaryFailureCause? {
        guard case .unsupportedLanguage(_, let code) = error as? SummaryProviderError else { return nil }
        return .unsupportedLanguage(languageCode: code)
    }
}

nonisolated struct SummaryFailureNote: Codable, Equatable, Sendable {
    let message: String
    let provider: String
    let date: Date
    /// Absent in notes written before 19.10.2026 — those read as the
    /// ordinary kind, with Try again.
    var cause: SummaryFailureCause?

    static let fileName = ".summary_failure.json"
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SummaryFailureNote")

    /// What the banner says in the language case: the one sentence,
    /// without the "choose another provider" the button already is.
    var languageSentence: String? {
        guard case .unsupportedLanguage(let code) = cause else { return nil }
        return AppleIntelligenceLanguageGate.cannotWritePhrase(provider: provider, languageCode: code)
    }

    /// Returns what it wrote, for `announce`.
    @discardableResult
    static func write(message: String, provider: String, cause: SummaryFailureCause? = nil, in directory: URL) -> SummaryFailureNote {
        let note = SummaryFailureNote(message: message, provider: provider, date: Date(), cause: cause)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(note).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            log.error("Summary failure note not saved: \(error.localizedDescription, privacy: .public)")
        }
        return note
    }

    static func read(in directory: URL) -> SummaryFailureNote? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SummaryFailureNote.self, from: data)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// Say it now, with the way to fix it — the note keeps it for later.
    /// A language the provider can't write names the fix on the button,
    /// so the text says only what went wrong.
    @MainActor
    static func announce(_ note: SummaryFailureNote) {
        SessionStore.shared.summaryFailureRevision += 1
        let actionLabel: String
        switch note.cause {
        case .unsupportedLanguage: actionLabel = String(localized: "Choose another provider")
        case nil: actionLabel = String(localized: "Summary settings")
        }
        ToastCenter.shared.showAction(
            String(localized: "No summary — \(note.languageSentence ?? note.message)"),
            actionLabel: actionLabel,
            style: .warning,
            duration: .seconds(15)
        ) {
            AppNavigation.shared.openInSettings(.ai, row: .summaryProvider)
        }
    }
}
