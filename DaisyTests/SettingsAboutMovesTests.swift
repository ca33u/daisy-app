//
//  SettingsAboutMovesTests.swift
//  DaisyTests
//
//  Settings restructure S3 (Egor 24.10.2026): Updates from About to
//  General; the improvement counts, crash reports and logs from About to
//  Privacy; the calendars from Privacy to Connections, with their old
//  ids still resolving. That every row is anchored once is S1's test.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct SettingsAboutMovesTests {
    @Test func movedRowsSitOnTheirNewTabs() {
        for row in [SettingsRow.autoUpdate, .betaChannel, .whatsNew] {
            #expect(row.tab == .general, "\(row)")
        }
        for row in [SettingsRow.improveDaisy, .crashReports, .logReport] {
            #expect(row.tab == .privacy, "\(row)")
        }
        for row in [SettingsRow.calendarApple, .calendarGoogle] {
            #expect(row.tab == .connections, "\(row)")
            #expect(row.connectionSection == .calendar, "\(row)")
        }
    }

    @Test func noCalendarRowIsLeftOnPrivacy() {
        let privacy = SettingsRow.allCases.filter { $0.tab == .privacy }
        #expect(!privacy.isEmpty)
        for row in privacy {
            #expect(!row.rawValue.localizedCaseInsensitiveContains("calendar"), "\(row.rawValue)")
            #expect(!row.titleResource.key.localizedCaseInsensitiveContains("calendar"), "\(row.rawValue)")
        }
    }

    // MARK: - Old ids

    @Test func oldIdsResolveToTheMovedRows() {
        #expect(SettingsRow(rawValue: "privacy.calendarApple") == .calendarApple)
        #expect(SettingsRow(rawValue: "privacy.calendarGoogle") == .calendarGoogle)
        #expect(SettingsRow(rawValue: "ai.summaryTiming") == .summaryTiming)
        #expect(SettingsRow(rawValue: "connections.calendarApple") == .calendarApple)
        #expect(SettingsRow(rawValue: "privacy.nothing") == nil)
    }

    @Test func currentIdsRoundTripAndNoAliasShadowsOne() {
        for row in SettingsRow.allCases {
            #expect(SettingsRow(rawValue: row.rawValue) == row)
        }
        let live = Set(SettingsRow.allCases.map(\.rawValue))
        for (old, new) in SettingsRow.movedIDs {
            #expect(!live.contains(old), "\(old) is still a live id")
            #expect(live.contains(new), "\(old) points at \(new), which is no row")
        }
    }

    @Test func aCalendarLinkOpensConnectionsOnItsSegment() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openInSettings(.privacy, row: .calendarApple)
        #expect(nav.settingsTab == .connections)
        #expect(nav.pendingConnectionsSection == .calendar)
        #expect(nav.pendingSettingsRow == .calendarApple)

        nav.openInSettings(.general, row: .crashReports)
        #expect(nav.settingsTab == .privacy)
    }

    // MARK: - About

    /// About is about the app: of the settings, only the beta switch and
    /// the bug report are there.
    @Test func aboutHoldsNoSettings() throws {
        let about = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Daisy/AboutView.swift")
        let source = try String(contentsOf: about, encoding: .utf8)
        // «Get beta updates» (a Toggle on SparkleUpdater) and «Report a bug»
        // (LogReporter) are back on About since d94dd3b (Egor 01.11: where
        // people looked for them); the rest stays in Settings.
        for control in ["Picker(", "CrashReports", "ImprovementStats"] {
            #expect(!source.contains(control), "AboutView still has \(control)")
        }
        #expect(source.components(separatedBy: "Toggle(").count - 1 == 1, "AboutView has one switch: beta updates")
    }
}
