//
//  SettingsFrameTests.swift
//  DaisyTests
//
//  Settings restructure S1 (Egor 24.10.2026): eight tabs with the old
//  six still landing where their content went, the row table search and
//  deep links read, and the search filter itself.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct SettingsFrameTests {
    // MARK: - Tabs

    @Test func eightTabsInPlanOrder() {
        #expect(SettingsTab.allCases == [.general, .shortcuts, .meetings, .dictation,
                                         .ai, .library, .connections, .privacy])
        #expect(SettingsView.tabOrder == SettingsTab.allCases)
    }

    @Test func oldRawValuesLandOnTheirNewTabs() {
        #expect(SettingsTab(rawValue: "recording") == .meetings)
        #expect(SettingsTab(rawValue: "transcription") == .dictation)
        #expect(SettingsTab(rawValue: "summary") == .ai)
        #expect(SettingsTab(rawValue: "voice") == .ai)
        #expect(SettingsTab(rawValue: "permissions") == .privacy)
        #expect(SettingsTab(rawValue: "general") == .general)
        #expect(SettingsTab(rawValue: "connections") == .connections)
        #expect(SettingsTab(rawValue: "capture") == nil)
    }

    @Test func newRawValuesRoundTrip() {
        for tab in SettingsTab.allCases {
            #expect(SettingsTab(rawValue: tab.rawValue) == tab)
        }
    }

    // MARK: - Deep links

    @Test func aRowLinkOpensTheRowsOwnTab() {
        let nav = AppNavigation.shared
        let before = (nav.section, nav.pendingSettingsTab, nav.pendingSettingsRow, nav.pendingConnectionsSection)
        defer {
            nav.section = before.0
            nav.pendingSettingsTab = before.1
            nav.pendingSettingsRow = before.2
            nav.pendingConnectionsSection = before.3
        }

        nav.openInSettings(.general, row: .layoutFixer)
        #expect(nav.section == .settings)
        #expect(nav.pendingSettingsTab == .dictation)
        #expect(nav.pendingSettingsRow == .layoutFixer)

        nav.openInSettings(.connections, row: .notion)
        #expect(nav.pendingSettingsTab == .connections)
        #expect(nav.pendingConnectionsSection == .autoRouting)

        nav.openInSettings(.meetings)
        #expect(nav.pendingSettingsTab == .meetings)
        #expect(nav.pendingSettingsRow == nil)
    }

    @Test func aHiddenRowLandsOnItsStandIn() {
        #expect(SettingsRow.layoutFixHotkey.target(.init(layoutFixEnabled: false)) == .layoutFixer)
        #expect(SettingsRow.layoutFixAsYouType.target(.init(layoutFixEnabled: false)) == .layoutFixer)
        #expect(SettingsRow.microphone.target(.init(layoutFixEnabled: false)) == .microphone)
        #expect(SettingsRow.layoutFixHotkey.target(.init(layoutFixEnabled: true)) == .layoutFixHotkey)
        // A stand-in lives on the same tab, or the link would switch tabs
        // and then find nothing to light.
        for row in SettingsRow.allCases {
            if let standIn = row.standIn { #expect(standIn.tab == row.tab) }
        }
    }

    // MARK: - The row table

    @Test func rowIdsNameTheirTab() {
        for row in SettingsRow.allCases {
            #expect(row.rawValue.hasPrefix(row.tab.rawValue + "."), "\(row.rawValue) sits on \(row.tab)")
        }
        #expect(Set(SettingsRow.allCases.map(\.rawValue)).count == SettingsRow.allCases.count)
    }

    @Test func everyTabHasRowsAndEveryRowATitle() {
        for tab in SettingsTab.allCases {
            #expect(SettingsRow.allCases.contains { $0.tab == tab }, "\(tab) has no rows")
        }
        for row in SettingsRow.allCases {
            #expect(!row.title.isEmpty)
        }
        // Two rows with one title on one tab would be indistinguishable
        // in the results list.
        let pairs = SettingsRow.allCases.map { "\($0.tab.rawValue)|\($0.titleResource.key)" }
        #expect(Set(pairs).count == pairs.count)
    }

    /// Every case is anchored by exactly one `.settingsRow(.case)` in the
    /// app's sources — so a search hit or a link always has a row to
    /// scroll to, and no two views claim one id.
    @Test func everyRowIsAnchoredOnceInTheViews() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Daisy")
        let files = try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no sources at \(appSources.path)")
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for row in SettingsRow.allCases {
            let anchors = source.components(separatedBy: ".settingsRow(.\(row))").count - 1
            #expect(anchors == 1, "\(row) is anchored \(anchors) times")
        }
    }

    // MARK: - Search

    private func entry(_ row: SettingsRow, _ titles: String...) -> SettingsSearch.Entry {
        SettingsSearch.Entry(row: row, titles: titles)
    }

    @Test func normalizationIgnoresCaseDiacriticsAndSpaces() {
        #expect(SettingsSearch.normalize("  Ёлка   ПАЛКА ") == "елка палка")
        #expect(SettingsSearch.normalize("Café") == "cafe")
        let entries = [entry(.theme, "Тёмная тема")]
        #expect(SettingsSearch.results(for: "ТЕМНАЯ", in: entries) == [.theme])
        #expect(SettingsSearch.results(for: "темная  тема", in: entries) == [.theme])
    }

    @Test func emptyQueryFindsNothing() {
        let entries = [entry(.theme, "Theme")]
        #expect(SettingsSearch.results(for: "", in: entries).isEmpty)
        #expect(SettingsSearch.results(for: "   ", in: entries).isEmpty)
        #expect(SettingsSearch.results(for: "zzz", in: entries).isEmpty)
    }

    @Test func prefixBeforeWordStartBeforeSubstring() {
        let entries = [
            entry(.splitMicVoices, "Split voices in my mic"),   // word start
            entry(.microphone, "Microphone"),                   // prefix
            entry(.removeEcho, "Remove echo from my mic"),       // word start
            entry(.dictationHotkey, "Dynamic"),                 // substring only
        ]
        #expect(SettingsSearch.results(for: "mic", in: entries)
                == [.microphone, .splitMicVoices, .removeEcho, .dictationHotkey])
    }

    @Test func eitherLanguageFindsTheRow() {
        let entries = [entry(.microphone, "Микрофон", "Microphone"), entry(.theme, "Тема", "Theme")]
        #expect(SettingsSearch.results(for: "микро", in: entries) == [.microphone])
        #expect(SettingsSearch.results(for: "micro", in: entries) == [.microphone])
        // The better of the two titles decides the rank.
        let ranked = [entry(.theme, "Оформление", "Theme"), entry(.removeEcho, "Тема эха")]
        #expect(SettingsSearch.results(for: "the", in: ranked) == [.theme])
        #expect(SettingsSearch.results(for: "тема", in: ranked) == [.removeEcho])
    }

    @Test func liveTableFindsRowsByEnglishTitle() {
        // Whatever the UI language of the test host, the English titles
        // are always searchable.
        let hits = SettingsSearch.results(for: "summary provider", in: SettingsSearch.entries)
        #expect(hits.first == .summaryProvider)
    }
}
