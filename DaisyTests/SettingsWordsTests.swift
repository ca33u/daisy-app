//
//  SettingsWordsTests.swift
//  DaisyTests
//
//  Settings restructure S4 (Egor 24.10.2026): one dictionary for the row
//  titles, and every message that sends someone into Settings names a
//  place that exists — through `SettingsRow.path`. The scans below catch
//  the old arrow paths («Settings → Summary»…); a vaguer «in Settings»
//  is left to review.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct SettingsWordsTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
    }

    /// key → (EN value, RU value). EN is the key itself unless the entry
    /// is keyed and carries its own English.
    private static func catalog() throws -> [String: (en: String, ru: String?)] {
        let url = repositoryRoot.appendingPathComponent("Daisy/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        var result: [String: (en: String, ru: String?)] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: Any]
            func value(_ language: String) -> String? {
                ((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            result[key] = (value("en") ?? key, value("ru"))
        }
        return result
    }

    /// The places that are gone: the old tabs and the rows they had.
    private static let oldPathsEN = [
        "Summary Provider",
        "Settings → Recording",
        "Settings → Transcription",
        "Settings → Permissions",
        "Settings → Summary",
        "Transcription → Keyboard layout",
        "Recording → Shortcuts",
        "Privacy → Delete audio",
    ]
    private static let oldPathsRU = [
        "Настройки → Транскрипция",
        "Настройки → Расшифровка",
        "Настройки → Саммари",
        "Настройки → Разрешения",
        "Настройки → Запись",
        "Транскрипция → Раскладка",
        "Приватность → Удалять аудио",
    ]

    @Test func theCatalogNamesNoOldPath() throws {
        for (key, value) in try Self.catalog() {
            for old in Self.oldPathsEN {
                #expect(!value.en.contains(old), "\(key) says \(old)")
            }
            for old in Self.oldPathsRU {
                #expect(!(value.ru ?? "").contains(old), "\(key) says \(old) in Russian")
            }
        }
    }

    /// Strings that never reach the catalog (MCP replies, plain literals)
    /// count too; comments don't.
    @Test func theSourcesNameNoOldPath() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Daisy")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no sources at \(sources.path)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for old in Self.oldPathsEN where code.contains(old) {
                    Issue.record("\(file.lastPathComponent):\(index + 1) says \(old)")
                }
            }
        }
    }

    @Test func everyRowTitleHasRussian() throws {
        let catalog = try Self.catalog()
        for row in SettingsRow.allCases {
            let key = row.titleResource.key
            let ru = catalog[key]?.ru ?? ""
            #expect(!ru.isEmpty, "\(row): «\(key)» has no Russian")
        }
    }

    /// The dictionary (plan «Один словарь»): each term is one row's title,
    /// and the words it replaced are nobody's.
    @Test func theDictionaryTermsAreOneRowEach() {
        let titles = SettingsRow.allCases.map { $0.titleResource.key }
        for term in ["Interface language", "Transcription language", "Summary language",
                     "Model: meetings", "Model: dictation", "Processing plan"] {
            #expect(titles.filter { $0 == term }.count == 1, "\(term)")
        }
        for gone in ["Language", "Meeting model", "Dictation engine", "Meeting processing", "Models"] {
            #expect(!titles.contains(gone), "\(gone) is still a row title")
        }
        #expect(SettingsRow.interfaceLanguage.titleResource.key == "Interface language")
        #expect(SettingsRow.transcriptionLanguage.titleResource.key == "Transcription language")
        #expect(SettingsRow.summaryLanguage.titleResource.key == "Summary language")
        #expect(SettingsRow.meetingModel.titleResource.key == "Model: meetings")
        #expect(SettingsRow.dictationEngine.titleResource.key == "Model: dictation")
    }

    /// The views use the same words as the table, and the theme and the
    /// interface language both say «System» for «follow macOS».
    @Test func theViewsSayTheDictionaryWords() throws {
        let settings = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Daisy/SettingsView.swift"), encoding: .utf8)
        for label in ["Picker(\"Interface language\"", "Picker(\"Transcription language\"",
                      "Picker(\"Summary language\"", "\"Model: meetings\",", "\"Model: dictation\","] {
            #expect(settings.contains(label), "\(label)")
        }
        #expect(!settings.contains("Picker(\"Language\""))
        #expect(!settings.contains("Text(\"Automatic\").tag(AppearancePreference.system)"))
        #expect(settings.contains("Text(\"System\").tag(AppearancePreference.system)"))
        #expect(try Self.catalog()["System"]?.ru == "Как в системе")

        let audio = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Daisy/RecordingAudioSettingsSection.swift"),
            encoding: .utf8)
        #expect(audio.contains("Text(\"Sound\")"))
        #expect(!audio.contains("Audio diagnostics"))
    }

    @Test func aPathIsTheTabAndTheRow() {
        #expect(SettingsRow.summaryProvider.path == "Settings → AI → Summary provider")
        #expect(SettingsRow.audioStorage.path == "Settings → Library → Audio storage")
        #expect(SettingsRow.layoutFixer.path == "Settings → Dictation → Layout fixer")
        #expect(SettingsRow.meetingModel.path == "Settings → Meetings → Model: meetings")
        #expect(SettingsTab.shortcuts.path == "Settings → Shortcuts")
    }

    @Test func providerErrorsNameTheNewPath() {
        let error = SummaryProviderError.missingAPIKey(provider: "Anthropic")
        #expect(error.localizedDescription == "Anthropic: API key is missing. Open Settings → AI → Summary provider to add it.")
    }

    @Test func whatsNewTellsAboutSettings() throws {
        #expect(WhatsNew.edition.hasSuffix("-e"))
        let entry = try #require(try Self.catalog()["whatsNew.settings"])
        #expect(entry.en == "Settings are eight tabs now, with search (⌘F)")
        #expect(entry.ru == "Настройки — восемь вкладок и поиск (⌘F)")
    }
}
