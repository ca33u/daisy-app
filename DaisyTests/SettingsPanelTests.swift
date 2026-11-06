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

import AppKit
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
    private let savedSearch = AppNavigation.shared.settingsSearch
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
        nav.settingsSearch = savedSearch
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

    // MARK: - Pages of the main window close the sheet

    /// Open Library, a toast's «Open», an import: the page would change
    /// unseen under the sheet — the sheet closes, even when the page is
    /// the one already showing.
    @Test func goingToAMainWindowPageClosesTheSheet() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.section = .library
        nav.openSettings()
        nav.openInLibrary("2026-11-01 10-00-00")
        #expect(nav.panel == nil)
        #expect(nav.section == .library)

        nav.openAbout()
        nav.importFiles([URL(fileURLWithPath: "/tmp/nothing.m4a")])
        #expect(nav.panel == nil)
        nav.pendingImportURLs = nil
        nav.pendingLibrarySelection = nil

        nav.openSettings()
        nav.section = .home
        #expect(nav.panel == nil)
    }

    /// Daisy going to the session it just finished (`showSessionAfterStop`)
    /// leaves a sheet the person is working in where it is.
    @Test func backgroundNavigationKeepsTheSheet() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.section = .home
        nav.openSettings()
        nav.openInLibrary("2026-11-01 10-00-00", userInitiated: false)
        #expect(nav.panel == .settings)
        #expect(nav.section == .library)
        // …and the next move by the person still closes it.
        nav.section = .home
        #expect(nav.panel == nil)
        nav.pendingLibrarySelection = nil
    }

    /// The finished-session and finished-import auto-opens are Daisy's own
    /// moves.
    @Test func theAutoOpensAreBackgroundNavigation() throws {
        let main = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy/MainView.swift"), encoding: .utf8)
        #expect(main.contains("openInLibrary(id, userInitiated: false)"))
        let importSheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy/AudioImportSheet.swift"), encoding: .utf8)
        #expect(importSheet.contains("openInLibrary(only.sessionID, userInitiated: false)"))
    }

    // MARK: - ⌘W

    /// A held ⌘W, or a second one while the sheet goes, stays with the
    /// sheet instead of closing the main window.
    @Test func commandWAfterClosingIsSwallowedForAMoment() {
        // A close of its own, so the test doesn't lean on another test
        // having closed a panel first (closedAt starts at -infinity).
        AppNavigation.shared.openSettings()
        AppNavigation.shared.closePanel()
        let closed = PanelKeys.closedAt
        // Long after any close: a fresh ⌘W is the window's.
        #expect(!PanelKeys.swallowsCommandW(isRepeat: false, now: closed + 10))
        // Within half a second of the close: kept.
        #expect(PanelKeys.swallowsCommandW(isRepeat: false, now: closed + 0.2))
        #expect(!PanelKeys.swallowsCommandW(isRepeat: false, now: closed + 0.6))
        // Closed by Escape or ×, then ⌘W pressed and held at once: the
        // press and its repeats stay with the sheet.
        #expect(PanelKeys.swallowsCommandW(isRepeat: false, now: closed + 0.1))
        #expect(PanelKeys.swallowsCommandW(isRepeat: true, now: closed + 0.7))
        // A fresh press later is the window's again, repeats too.
        #expect(!PanelKeys.swallowsCommandW(isRepeat: false, now: closed + 3))
        #expect(!PanelKeys.swallowsCommandW(isRepeat: true, now: closed + 3.1))
    }

    // MARK: - A click around the sheet

    /// A press on the backdrop released where it went down closes the
    /// sheet; one that travelled (a drag of the window), was released in
    /// another window, or started off the backdrop doesn't.
    @Test func backdropClickIsAPressReleasedInPlace() {
        let windows = (NSObject(), NSObject())   // held: ids of live objects
        let main = ObjectIdentifier(windows.0)
        let other = ObjectIdentifier(windows.1)
        defer { withExtendedLifetime(windows) {} }
        var clicks = PanelBackdrop.Clicks()
        var closes = false

        clicks.press(window: main, at: NSPoint(x: 40, y: 40), onBackdrop: true, activating: false)
        closes = clicks.release(window: main, at: NSPoint(x: 42, y: 43))
        #expect(closes)

        // Dragged: the window moved by its top, or a selection swept out.
        clicks.press(window: main, at: NSPoint(x: 40, y: 40), onBackdrop: true, activating: false)
        closes = clicks.release(window: main, at: NSPoint(x: 140, y: 40))
        #expect(!closes)

        // Pressed inside the sheet (not the backdrop), released anywhere.
        clicks.press(window: main, at: NSPoint(x: 40, y: 40), onBackdrop: false, activating: false)
        closes = clicks.release(window: main, at: NSPoint(x: 40, y: 40))
        #expect(!closes)

        // Released in another window.
        clicks.press(window: main, at: NSPoint(x: 40, y: 40), onBackdrop: true, activating: false)
        closes = clicks.release(window: other, at: NSPoint(x: 40, y: 40))
        #expect(!closes)

        // A release with no press of ours before it.
        closes = clicks.release(window: main, at: NSPoint(x: 40, y: 40))
        #expect(!closes)
    }

    /// The click that brings Daisy back from another app only activates.
    @Test func activatingClickKeepsTheSheet() {
        let window = NSObject()
        let main = ObjectIdentifier(window)
        defer { withExtendedLifetime(window) {} }
        var clicks = PanelBackdrop.Clicks()
        clicks.press(window: main, at: NSPoint(x: 10, y: 10), onBackdrop: true, activating: true)
        let closes = clicks.release(window: main, at: NSPoint(x: 10, y: 10))
        #expect(!closes)
    }

    /// The rest of a double click that closed the sheet is swallowed —
    /// in that window, within the double-click interval — and nothing else.
    @Test func restOfAClosingDoubleClickIsSwallowed() {
        let windows = (NSObject(), NSObject())   // held: ids of live objects
        let main = ObjectIdentifier(windows.0)
        let other = ObjectIdentifier(windows.1)
        defer { withExtendedLifetime(windows) {} }
        var clicks = PanelBackdrop.Clicks()
        var closes = false
        var swallowed = false

        // Nothing closed yet: a double click is the window's.
        swallowed = clicks.swallows(window: main, clickCount: 2, at: 0.1, doubleClickInterval: 0.5)
        #expect(!swallowed)

        clicks.press(window: main, at: .zero, onBackdrop: true, activating: false)
        closes = clicks.release(window: main, at: .zero)
        #expect(closes)
        // A click that ended on the backdrop but closed nothing (a sheet of
        // the sheet came up meanwhile): its double click is the window's.
        swallowed = clicks.swallows(window: main, clickCount: 2, at: 0.3, doubleClickInterval: 0.5)
        #expect(!swallowed)

        clicks.closedSheet(window: main, at: 10)
        swallowed = clicks.swallows(window: main, clickCount: 2, at: 10.2, doubleClickInterval: 0.5)
        #expect(swallowed)
        swallowed = clicks.swallows(window: main, clickCount: 3, at: 10.7, doubleClickInterval: 0.5)
        #expect(swallowed)
        swallowed = clicks.swallows(window: other, clickCount: 2, at: 10.2, doubleClickInterval: 0.5)
        #expect(!swallowed)
        swallowed = clicks.swallows(window: main, clickCount: 2, at: 11, doubleClickInterval: 0.5)
        #expect(!swallowed)

        // A fresh single click ends it: a later double click is the window's.
        swallowed = clicks.swallows(window: main, clickCount: 1, at: 12, doubleClickInterval: 0.5)
        #expect(!swallowed)
        swallowed = clicks.swallows(window: main, clickCount: 2, at: 12.2, doubleClickInterval: 0.5)
        #expect(!swallowed)
    }

    /// The monitor's handler on real windows: a main window with a sheet
    /// up as Settings' is. A click on the window around the sheet closes
    /// it; a click where the sheet is, a drag, the title bar's buttons, a
    /// modified click, the activating click and a click while a sheet of
    /// the sheet is up don't. The rest of a closing double click is
    /// swallowed.
    @Test func backdropClickOnRealWindows() throws {
        let sandbox = NavigationSandbox()
        let savedSheet = PanelKeys.sheetWindow
        defer {
            PanelKeys.sheetWindow = savedSheet
            // No closing click left behind for a window about to go.
            PanelBackdrop.clicks = PanelBackdrop.Clicks()
            sandbox.restore()
        }
        let nav = AppNavigation.shared

        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.alphaValue = 0             // on screen for AppKit, not for the eye
        main.orderFrontRegardless()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        main.beginSheet(sheet)
        defer {
            main.endSheet(sheet)
            sheet.orderOut(nil)
            main.orderOut(nil)
        }
        try #require(main.attachedSheet === sheet && sheet.sheetParent === main)
        PanelKeys.sheetWindow = sheet

        var now = ProcessInfo.processInfo.systemUptime + 1
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                   modifiers: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) -> NSEvent {
            now += 1   // clicks a second apart: never one double click
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                      timestamp: now, windowNumber: (window ?? main).windowNumber,
                                      context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        /// A press and release on `main`; true when the sheet closed.
        func click(at point: NSPoint, to end: NSPoint? = nil, modifiers: NSEvent.ModifierFlags = [],
                   active: Bool = true) -> Bool {
            nav.openSettings()
            _ = PanelBackdrop.handle(mouse(.leftMouseDown, at: point, modifiers: modifiers), appIsActive: active)
            _ = PanelBackdrop.handle(mouse(.leftMouseUp, at: end ?? point, modifiers: modifiers), appIsActive: active)
            return nav.panel == nil
        }

        let backdrop = NSPoint(x: 20, y: 20)   // bottom-left corner of the content
        let underSheet = main.convertPoint(fromScreen: NSPoint(x: sheet.frame.midX, y: sheet.frame.midY))
        let zoom = try #require(main.standardWindowButton(.zoomButton))
        let onZoom = NSPoint(x: zoom.convert(zoom.bounds, to: nil).midX, y: zoom.convert(zoom.bounds, to: nil).midY)

        #expect(click(at: backdrop))
        #expect(!click(at: underSheet))
        #expect(!click(at: backdrop, to: NSPoint(x: 220, y: 20)))     // a drag
        #expect(!click(at: onZoom))
        #expect(!click(at: backdrop, modifiers: .command))
        #expect(!click(at: backdrop, active: false))

        // Settings asked for while our card isn't the sheet on the window
        // (it waits for another sheet to close): the click isn't ours.
        PanelKeys.sheetWindow = nil
        #expect(!click(at: backdrop))
        #expect(nav.panel == .settings)
        PanelKeys.sheetWindow = sheet
        nav.closePanel()

        // Pressed with the sheet up, closed some other way before the
        // release: no closing click recorded, so a quick second click is
        // the window's.
        nav.openSettings()
        _ = PanelBackdrop.handle(mouse(.leftMouseDown, at: backdrop), appIsActive: true)
        nav.closePanel()
        _ = PanelBackdrop.handle(mouse(.leftMouseUp, at: backdrop), appIsActive: true)
        nav.openSettings()
        let afterNothingClosed = NSEvent.mouseEvent(with: .leftMouseDown, location: backdrop, modifierFlags: [],
                                                    timestamp: now + 0.1, windowNumber: main.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        #expect(!PanelBackdrop.handle(afterNothingClosed, appIsActive: true))
        nav.closePanel()

        // A sheet of the sheet (a confirmation) takes the click.
        let inner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        inner.isReleasedWhenClosed = false
        sheet.beginSheet(inner)
        try #require(sheet.attachedSheet === inner)
        #expect(!click(at: backdrop))
        sheet.endSheet(inner)
        inner.orderOut(nil)
        try #require(sheet.attachedSheet == nil)

        // A double click: the first closes, the second is swallowed — it
        // can't open what the window shows underneath.
        #expect(click(at: backdrop))
        let second = NSEvent.mouseEvent(with: .leftMouseDown, location: backdrop, modifierFlags: [],
                                        timestamp: now + 0.1, windowNumber: main.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 2, pressure: 1)!
        #expect(PanelBackdrop.handle(second, appIsActive: true))
    }

    // MARK: - Escape

    /// Escape's ladder: a Daisy-key command's own Escape, then the search,
    /// then a field being edited, then the sheet.
    @Test func escapeEmptiesTheSearchThenEndsEditingThenCloses() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared
        var ended = 0

        nav.openSettings()
        nav.settingsSearch = "mic"
        #expect(!PanelKeys.escape(keyTakenElsewhere: true, editing: true, endEditing: { ended += 1 }))
        #expect(nav.settingsSearch == "mic")
        #expect(nav.panel == .settings)

        #expect(PanelKeys.escape(keyTakenElsewhere: false, editing: true, endEditing: { ended += 1 }))
        #expect(nav.settingsSearch.isEmpty)
        #expect(ended == 0)
        #expect(nav.panel == .settings)

        #expect(PanelKeys.escape(keyTakenElsewhere: false, editing: true, endEditing: { ended += 1 }))
        #expect(ended == 1)
        #expect(nav.panel == .settings)

        #expect(PanelKeys.escape(keyTakenElsewhere: false, editing: false, endEditing: { ended += 1 }))
        #expect(nav.panel == nil)
    }

    /// The empty search holds the cursor only because a new sheet gives it
    /// focus: Escape closes at once.
    @Test func escapeInTheEmptySearchCloses() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared
        var ended = 0

        nav.openSettings()
        #expect(PanelKeys.escape(keyTakenElsewhere: false, editing: true, editingSearch: true,
                                 endEditing: { ended += 1 }))
        #expect(ended == 0)
        #expect(nav.panel == nil)
    }

    /// ⌘W is the letter W — or the W key under a layout with no Latin
    /// letter there; never AZERTY's Z or Dvorak's comma on that key.
    @Test func commandWOnEveryLayout() {
        #expect(PanelKeys.isCommandW(keyCode: 13, character: "w"))      // US
        #expect(PanelKeys.isCommandW(keyCode: 13, character: "ц"))      // Russian
        #expect(PanelKeys.isCommandW(keyCode: 6, character: "w"))       // AZERTY's W
        #expect(!PanelKeys.isCommandW(keyCode: 13, character: "z"))     // AZERTY's Z
        #expect(!PanelKeys.isCommandW(keyCode: 13, character: ","))     // Dvorak
        #expect(!PanelKeys.isCommandW(keyCode: 1, character: "s"))
    }

    /// However Settings close — the ×, a page of the main window, What's
    /// New, About — the search goes with them.
    @Test func closingSettingsDropsTheSearch() {
        let sandbox = NavigationSandbox()
        defer { sandbox.restore() }
        let nav = AppNavigation.shared

        nav.openSettings()
        nav.settingsSearch = "mic"
        nav.closePanel()
        #expect(nav.settingsSearch.isEmpty)

        nav.openSettings()
        nav.settingsSearch = "mic"
        nav.openInLibrary("2026-11-01 10-00-00")
        #expect(nav.settingsSearch.isEmpty)
        nav.pendingLibrarySelection = nil

        nav.openSettings()
        nav.settingsSearch = "mic"
        nav.openAbout()
        #expect(nav.settingsSearch.isEmpty)
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
