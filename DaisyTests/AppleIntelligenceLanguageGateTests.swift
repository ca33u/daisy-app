//
//  AppleIntelligenceLanguageGateTests.swift
//  DaisyTests
//
//  Apple Intelligence and a language it can't write: the Settings
//  warning comes before the first recording, and a meeting that got no
//  summary for that reason keeps a note the banner can tell apart from
//  an ordinary failure (backlog 32 A-3, 19.10.2026).
//

import Foundation
import Testing
@testable import Daisy

struct AppleIntelligenceLanguageGateTests {
    /// What macOS 26's model writes today, as the live check would answer.
    private static func writes(_ code: String) -> Bool {
        ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"].contains(code)
    }

    private func warning(
        provider: SummaryProviderKind = .appleIntelligence,
        summaryLanguage: String = "auto",
        interface: String?,
        transcription: String
    ) -> String? {
        AppleIntelligenceLanguageGate.languageToWarnAbout(
            provider: provider,
            summaryLanguage: summaryLanguage,
            interfaceLanguage: interface,
            transcriptionLanguage: transcription,
            supports: Self.writes
        )
    }

    @Test func russianInterfaceOnAutoWarns() {
        #expect(warning(interface: "ru", transcription: "auto") == "ru")
    }

    @Test func englishInterfaceOnAutoIsQuiet() {
        #expect(warning(interface: "en", transcription: "auto") == nil)
        #expect(warning(interface: nil, transcription: "auto") == nil)
    }

    @Test func pinnedTranscriptionLanguageDecides() {
        // Meetings decoded in Russian: warned, whatever the interface.
        #expect(warning(interface: "en", transcription: "ru") == "ru")
        #expect(warning(interface: "en", transcription: "uk-UA") == "uk")
        // Meetings decoded in English: summaries will come, a Russian
        // interface changes nothing.
        #expect(warning(interface: "ru", transcription: "en") == nil)
    }

    @Test func onlyAppleIntelligenceHasALanguageItCannotWrite() {
        #expect(warning(provider: .anthropic, interface: "ru", transcription: "ru") == nil)
        #expect(warning(provider: .ollama, interface: "ru", transcription: "auto") == nil)
    }

    @Test func anExplicitSummaryLanguageHasItsOwnWarning() {
        #expect(warning(summaryLanguage: "ru", interface: "ru", transcription: "ru") == nil)
        #expect(warning(summaryLanguage: "en", interface: "ru", transcription: "auto") == nil)
        // The stored default and the picker's Auto read the same.
        #expect(warning(summaryLanguage: "", interface: "ru", transcription: "auto") == "ru")
    }

    @Test func interfaceLanguageIsTheOverrideElseTheSystem() {
        #expect(AppleIntelligenceLanguageGate.interfaceLanguage(override: "ru", preferred: ["en-US"]) == "ru")
        #expect(AppleIntelligenceLanguageGate.interfaceLanguage(override: "system", preferred: ["ru-RU", "en"]) == "ru")
        #expect(AppleIntelligenceLanguageGate.interfaceLanguage(override: nil, preferred: ["en-GB"]) == "en")
        #expect(AppleIntelligenceLanguageGate.interfaceLanguage(override: nil, preferred: []) == nil)
    }

    @Test func theSentenceNamesTheLanguage() {
        #expect(AppleIntelligenceLanguageGate.cannotWritePhrase(provider: "Apple Intelligence", languageCode: "ru")
                == "Apple Intelligence doesn't write in Russian yet.")
        #expect(AppleIntelligenceLanguageGate.cannotWritePhrase(provider: "Apple Intelligence", languageCode: "ru-RU")
                == "Apple Intelligence doesn't write in Russian yet.")
        #expect(AppleIntelligenceLanguageGate.cannotWritePhrase(provider: "Apple Intelligence", languageCode: nil)
                == "Apple Intelligence doesn't write in this language yet.")
        #expect(AppleIntelligenceLanguageGate.cannotWritePhrase(provider: "Apple Intelligence", languageCode: "kk")
                == "Apple Intelligence doesn't write in Kazakh yet.")
    }

    @Test func theProviderErrorCarriesTheCause() {
        let error = SummaryProviderError.unsupportedLanguage(provider: "Apple Intelligence", languageCode: "ru")
        #expect(error.localizedDescription
                == "Apple Intelligence doesn't write in Russian yet. Choose another provider in Settings → Summary.")
        #expect(SummaryFailureCause.of(error) == .unsupportedLanguage(languageCode: "ru"))
        #expect(SummaryFailureCause.of(SummaryProviderError.transcriptTooShort) == nil)
        #expect(SummaryFailureCause.of(CancellationError()) == nil)
    }

    @Test func theNoteKeepsTheCauseAndReadsOldNotes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        SummaryFailureNote.write(
            message: "Apple Intelligence doesn't write in Russian yet.",
            provider: "Apple Intelligence",
            cause: .unsupportedLanguage(languageCode: "ru"),
            in: directory
        )
        let note = try #require(SummaryFailureNote.read(in: directory))
        #expect(note.cause == .unsupportedLanguage(languageCode: "ru"))
        #expect(note.languageSentence == "Apple Intelligence doesn't write in Russian yet.")

        // An ordinary failure, and a note from before the field existed:
        // no cause, no language sentence — the banner keeps Try again.
        SummaryFailureNote.write(message: "HTTP 500", provider: "Anthropic", in: directory)
        let plain = try #require(SummaryFailureNote.read(in: directory))
        #expect(plain.cause == nil)
        #expect(plain.languageSentence == nil)

        let old = #"{"message":"it doesn't write in Russian yet.","provider":"Apple Intelligence","date":"2026-10-07T10:00:00Z"}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent(SummaryFailureNote.fileName))
        let legacy = try #require(SummaryFailureNote.read(in: directory))
        #expect(legacy.cause == nil)
        #expect(legacy.message == "it doesn't write in Russian yet.")
    }
}
