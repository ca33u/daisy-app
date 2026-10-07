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

nonisolated struct SummaryFailureNote: Codable, Equatable, Sendable {
    let message: String
    let provider: String
    let date: Date

    static let fileName = ".summary_failure.json"
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SummaryFailureNote")

    static func write(message: String, provider: String, in directory: URL) {
        let note = SummaryFailureNote(message: message, provider: provider, date: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(note).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            log.error("Summary failure note not saved: \(error.localizedDescription, privacy: .public)")
        }
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
    @MainActor
    static func announce(_ message: String) {
        SessionStore.shared.summaryFailureRevision += 1
        ToastCenter.shared.showAction(
            String(localized: "No summary — \(message)"),
            actionLabel: String(localized: "Summary settings"),
            style: .warning,
            duration: .seconds(15)
        ) {
            AppNavigation.shared.pendingSettingsTab = .summary
            AppNavigation.shared.section = .settings
        }
    }
}
