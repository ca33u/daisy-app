//
//  SettingsWindowTests.swift
//  DaisyTests
//
//  Settings in their own window (Egor, 31.10.2026): a sidebar of the
//  eight tabs and About, opened over the main window by ⌘,, «About
//  Daisy», the main sidebar's two bottom rows and every link into
//  Settings — on the link's tab, with its row pending for the page.
//

import Foundation
import Testing
@testable import Daisy

/// AppNavigation's link state saved for the length of a test, with the
/// window openings recorded instead of performed — no window comes up in
/// the test host.
@MainActor
final class NavigationSandbox {
    private(set) var opened: [String] = []
    private let nav = AppNavigation.shared
    private let saved: (MainSection, SettingsPane, SettingsRow?, ConnectionSection?, (@MainActor (String) -> Void)?)

    init() {
        saved = (nav.section, nav.settingsPane, nav.pendingSettingsRow,
                 nav.pendingConnectionsSection, nav.windowOpener)
        nav.windowOpener = { [weak self] id in self?.opened.append(id) }
    }

    func restore() {
        nav.section = saved.0
        nav.settingsPane = saved.1
        nav.pendingSettingsRow = saved.2
        nav.pendingConnectionsSection = saved.3
        nav.windowOpener = saved.4
    }
}

@MainActor
struct SettingsWindowTests {
    // MARK: - The sidebar

    @Test func theSidebarListsTheEightTabsThenAbout() {
        #expect(SettingsPane.tabs.count == 8)
        #expect(SettingsPane.tabs == SettingsTab.allCases.map { .tab($0) })
        #expect(!SettingsPane.tabs.contains(.about))
        #expect(SettingsPane.tab(.ai).title == SettingsTab.ai.title)
        #expect(SettingsPane.about.title == String(localized: "About"))
    }

    /// Settings and About are no longer pages of the main window.
    @Test func theMainWindowHasNoSettingsOrAboutPage() {
        #expect(MainSection.allCases == [.home, .library, .dictation, .voice])
        #expect(MainSection.primaryCases == MainSection.allCases)
        #expect(SidebarUtility.allCases == [.settings, .about])
    }

    // MARK: - Opening the window

    @Test func aLinkOpensTheWindowOnItsTabAndLeavesTheMainPageAlone() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared
        nav.section = .library

        nav.openInSettings(.general, row: .microphone)
        #expect(sandbox.opened == [SettingsWindow.id])
        #expect(nav.settingsPane == .tab(.meetings))
        #expect(nav.pendingSettingsRow == .microphone)
        #expect(nav.section == .library)
    }

    @Test func aTabLinkWithoutARowClearsAPendingRow() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openInSettings(.ai, row: .summaryProvider)
        nav.openInSettings(.library)
        #expect(nav.settingsPane == .tab(.library))
        #expect(nav.pendingSettingsRow == nil)
        #expect(sandbox.opened == [SettingsWindow.id, SettingsWindow.id])
    }

    @Test func aConnectionsLinkPicksItsSegment() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openInConnections(.mcpServer)
        #expect(nav.settingsPane == .tab(.connections))
        #expect(nav.pendingConnectionsSection == .mcpServer)
        #expect(nav.pendingSettingsRow == nil)
        #expect(sandbox.opened == [SettingsWindow.id])
    }

    /// ⌘, and the sidebar's Settings row reopen on the page left open.
    @Test func settingsReopensOnThePageItWasLeftOn() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.settingsPane = .tab(.privacy)
        nav.openSettings()
        #expect(nav.settingsPane == .tab(.privacy))

        SidebarUtility.settings.open()
        #expect(nav.settingsPane == .tab(.privacy))
        #expect(sandbox.opened == [SettingsWindow.id, SettingsWindow.id])
    }

    /// «About Daisy» and the sidebar's About row land on About.
    @Test func aboutOpensTheWindowOnAbout() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.settingsPane = .tab(.shortcuts)
        nav.openAbout()
        #expect(nav.settingsPane == .about)

        nav.settingsPane = .tab(.shortcuts)
        SidebarUtility.about.open()
        #expect(nav.settingsPane == .about)
        #expect(sandbox.opened == [SettingsWindow.id, SettingsWindow.id])
    }

    @Test func everyLinkCountsSoTheWindowCanDropASearch() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        let before = nav.settingsLinkCount
        nav.openInSettings(.general)
        nav.openInSettings(.general)
        nav.openAbout()
        #expect(nav.settingsLinkCount == before &+ 3)
    }

    /// What's New, the tour and My style live in the main window: from
    /// Settings they bring it up.
    @Test func mainWindowPagesBringTheMainWindowUp() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        AppNavigation.shared.showMainWindow()
        #expect(sandbox.opened == ["main"])
    }

    // MARK: - Sources

    /// A link opens the Settings window by itself; bringing up the main
    /// window right after it would put the main window over Settings.
    @Test func noLinkIntoSettingsAlsoOpensTheMainWindow() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Daisy")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("openInSettings(") || line.contains("openInConnections(") {
                let next = lines[(index + 1)..<min(index + 4, lines.count)]
                if next.contains(where: { $0.contains("openMainWindow") || $0.contains("openWindow(id: \"main\")") }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
