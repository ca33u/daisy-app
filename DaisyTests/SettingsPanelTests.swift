//
//  SettingsPanelTests.swift
//  DaisyTests
//
//  Settings and About as sheets of the main window (Egor, 01.11.2026; a
//  window of its own 31.10–01.11), presented like «What's New»: Settings
//  with a sidebar of the eight tabs, About on its own with no sidebar. Shown by ⌘, / «About Daisy»,
//  the main sidebar's two bottom rows and every link into Settings — on
//  the link's tab, with its row pending for the page, the main window
//  brought up first.
//

import Foundation
import Testing
@testable import Daisy

/// AppNavigation's link and panel state saved for the length of a test,
/// with the main-window openings recorded instead of performed — no
/// window comes up in the test host.
@MainActor
final class NavigationSandbox {
    private(set) var opened: [String] = []
    private let nav = AppNavigation.shared
    private let saved: (MainSection, SettingsTab, SettingsRow?, ConnectionSection?,
                        (@MainActor (String) -> Void)?, MainPanel?, Bool)

    init() {
        saved = (nav.section, nav.settingsTab, nav.pendingSettingsRow,
                 nav.pendingConnectionsSection, nav.windowOpener,
                 nav.panel, nav.showsWhatsNew)
        nav.windowOpener = { [weak self] id in self?.opened.append(id) }
        nav.panel = nil
    }

    func restore() {
        nav.section = saved.0
        nav.settingsTab = saved.1
        nav.pendingSettingsRow = saved.2
        nav.pendingConnectionsSection = saved.3
        nav.windowOpener = saved.4
        nav.showsWhatsNew = saved.6
        nav.panel = saved.5
    }
}

@MainActor
struct SettingsPanelTests {
    // MARK: - The sidebar

    /// Settings' sidebar: the eight tabs, About not among them.
    @Test func settingsListTheEightTabs() {
        #expect(SettingsTab.allCases.count == 8)
        #expect(SettingsPanel.sidebarWidth > 0)
    }

    /// Settings and About are not pages of the main window's sidebar.
    @Test func theMainSidebarHasNoSettingsOrAboutPage() {
        #expect(MainSection.allCases == [.home, .library, .dictation, .voice])
        #expect(MainSection.primaryCases == MainSection.allCases)
        #expect(SidebarUtility.allCases == [.settings, .about])
    }

    // MARK: - The sheets

    /// Fixed sheets, short of the window by a margin when the window is
    /// smaller — down to the main window's floor. About is narrower.
    @Test func theSheetsHaveAFixedSizeThatFitsTheWindow() {
        #expect(PanelSize.width(SettingsPanel.preferredWidth, in: 1600) == SettingsPanel.preferredWidth)
        #expect(PanelSize.height(PanelSize.preferredHeight, in: 1200) == PanelSize.preferredHeight)
        let floor = MainWindowShellFloor.self
        #expect(PanelSize.width(SettingsPanel.preferredWidth, in: floor.width) == floor.width - 2 * PanelSize.margin)
        #expect(PanelSize.height(PanelSize.preferredHeight, in: floor.height) == floor.height - 2 * PanelSize.margin)
        #expect(PanelSize.width(SettingsPanel.preferredWidth, in: 10) == 0)
        #expect(AboutPanel.preferredWidth < SettingsPanel.preferredWidth)
        #expect(PanelSize.width(AboutPanel.preferredWidth, in: floor.width) == AboutPanel.preferredWidth)
    }

    // MARK: - Showing it

    @Test func aLinkShowsSettingsOnItsTabOverTheMainWindow() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared
        nav.section = .library

        nav.openInSettings(.general, row: .microphone)
        #expect(nav.panel == .settings)
        #expect(sandbox.opened == ["main"])
        #expect(nav.settingsTab == .meetings)
        #expect(nav.pendingSettingsRow == .microphone)
        // The page under the panel stays where it was.
        #expect(nav.section == .library)
    }

    @Test func aTabLinkWithoutARowClearsAPendingRow() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openInSettings(.ai, row: .summaryProvider)
        nav.openInSettings(.library)
        #expect(nav.settingsTab == .library)
        #expect(nav.pendingSettingsRow == nil)
        #expect(sandbox.opened == ["main", "main"])
    }

    @Test func aConnectionsLinkPicksItsSegment() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openInConnections(.mcpServer)
        #expect(nav.panel == .settings)
        #expect(nav.settingsTab == .connections)
        #expect(nav.pendingConnectionsSection == .mcpServer)
        #expect(nav.pendingSettingsRow == nil)
    }

    /// ⌘, and the sidebar's Settings row reopen on the page left open.
    @Test func settingsReopensOnThePageItWasLeftOn() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.settingsTab = .privacy
        nav.openSettings()
        #expect(nav.panel == .settings)
        #expect(nav.settingsTab == .privacy)

        nav.closePanel()
        #expect(nav.panel == nil)
        SidebarUtility.settings.open()
        #expect(nav.panel == .settings)
        #expect(nav.settingsTab == .privacy)
        #expect(sandbox.opened == ["main", "main"])
    }

    /// «About Daisy» and the sidebar's About row open the About sheet —
    /// and leave Settings' tab alone.
    @Test func aboutOpensItsOwnSheet() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.settingsTab = .shortcuts
        nav.openAbout()
        #expect(nav.panel == .about)
        #expect(nav.settingsTab == .shortcuts)

        nav.closePanel()
        SidebarUtility.about.open()
        #expect(nav.panel == .about)
        // ⌘, from About switches to Settings, on its tab.
        nav.openSettings()
        #expect(nav.panel == .settings)
        #expect(nav.settingsTab == .shortcuts)
        #expect(sandbox.opened == ["main", "main", "main"])
    }

    @Test func everyLinkCountsSoSettingsCanDropASearch() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        let before = nav.settingsLinkCount
        nav.openInSettings(.general)
        nav.openInSettings(.general)
        #expect(nav.settingsLinkCount == before &+ 2)
    }

    /// One sheet at a time: «What's New» closes Settings or About…
    @Test func whatsNewClosesTheSheet() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openSettings()
        nav.showsWhatsNew = true
        #expect(nav.panel == nil)
        nav.showsWhatsNew = false
        nav.openAbout()
        nav.showsWhatsNew = true
        #expect(nav.panel == nil)
    }

    /// …and Settings or About asked for over «What's New» replace it, so
    /// its flag never says it is up when it isn't.
    @Test func settingsReplaceWhatsNew() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.showsWhatsNew = true
        nav.openSettings()
        #expect(!nav.showsWhatsNew)
        #expect(nav.panel == .settings)

        nav.showsWhatsNew = true
        nav.openAbout()
        #expect(!nav.showsWhatsNew)
        #expect(nav.panel == .about)
    }

    // MARK: - Sources

    /// A link brings the main window up by itself; doing it again right
    /// after is noise.
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

    /// One window: no Settings scene left behind; the sheets ride on it.
    @Test func thereIsNoSettingsWindowScene() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy/DaisyApp.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        #expect(!source.contains("Window(\"Settings\""))
        #expect(source.contains("SettingsMenuItem(title: \"Settings…\", shortcut: \",\")"))
        let panel = try String(contentsOf: app.deletingLastPathComponent().appendingPathComponent("SettingsPanel.swift"),
                               encoding: .utf8)
        #expect(panel.contains(".sheet(item:"))
    }
}
