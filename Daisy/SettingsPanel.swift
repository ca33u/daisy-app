//
//  SettingsPanel.swift
//  Daisy
//
//  Settings and About as sheets of the main window (Egor, 01.11.2026,
//  after seeing 1.0.8.46's separate window): «не прям в другом окне окне,
//  а как бы это должно быть фиксированное окно внутри этого окна, а фон
//  чуть-чуть подблюрить», «у окна о приложении там не надо сайд меню» and
//  — of a first custom blur — «слишком жёсткий», softer like «What's
//  New». So they are presented the way «What's New» is: a SwiftUI
//  `.sheet` on the main window, whose softened backdrop macOS draws itself,
//  identical by construction. Two fixed cards:
//   • Settings — its own always-visible sidebar of the eight tabs of the
//     2026-10-23 structure, the row search at the top of it;
//   • About — no sidebar, just its page, narrower.
//  The × or Escape closes them (Escape in a search field with text clears
//  the search first). A sheet also keeps the window behind out of reach —
//  its own sheets, its toolbar, its menu commands.
//
//  From 31.10 to 01.11 Settings were a window of their own (`Window(id:
//  "settings")`, About a page of its sidebar). What that brought and
//  stays: links to a tab and a row with the highlight, ⌘, and «About
//  Daisy», the main sidebar's two buttons, reopening on the tab left
//  open, and `SettingsWiring` (a setting applies whichever windows are
//  open).
//
//  Shown by `AppNavigation.panel`; links from places with no main window
//  on screen (notifications, the widget, the menu bar) bring the main
//  window up first (`AppNavigation.openInSettings`).
//

import AppKit
import SwiftUI

/// A sheet of the main window: Settings or About.
enum MainPanel: Hashable, Identifiable, Sendable {
    case settings
    case about

    var id: Self { self }
}

/// Presents `AppNavigation.panel` as a sheet of the main window. One
/// sheet at a time: «What's New» and the tour close it first
/// (`AppNavigation.showsWhatsNew`, `OnboardingTourController.restart`);
/// asked for over «What's New», it replaces it (`openSettings`); over any
/// other sheet, it waits for that one to close.
struct MainPanelSheet: ViewModifier {
    let settings: AppSettings
    /// The tour owns the window; no sheet shows over it.
    let showsTour: Bool
    @Bindable private var nav = AppNavigation.shared
    /// What the sheet shows: `nav.panel`, once no other sheet is in the
    /// way. Presenting over another sheet makes SwiftUI swap it out while
    /// its owner still thinks it is up.
    @State private var shown: MainPanel?
    @State private var waiting: Task<Void, Never>?
    /// The window's content size, for the sheets' fixed size.
    @State private var windowSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            // The window's toasts — in the sheet instead while one covers it.
            .modifier(ToastOverlay(isHidden: shown != nil))
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { windowSize = geo.size }
                        .onChange(of: geo.size) { _, size in windowSize = size }
                }
            }
            .sheet(item: Binding(
                get: { shown },
                set: { panel in
                    shown = panel
                    if panel == nil { nav.closePanel() }
                }
            )) { panel in
                card(panel)
                    .modifier(ToastOverlay())
                    // The window the card is in — the one whose keys are
                    // the sheet's (PanelKeys).
                    // The probe also reports nil, late, when it leaves a
                    // window (Settings → About, a quick close and reopen):
                    // that must not wipe the current one. A window that
                    // goes away clears itself (weak).
                    .background(WindowFinder { window in
                        if let window { PanelKeys.sheetWindow = window }
                    })
            }
            .onChange(of: nav.panel, initial: true) { _, _ in sync() }
            .onAppear { PanelKeys.install() }
            // The tour starting (a replay from About or Help) closes the
            // sheet; one asked for during the tour isn't kept for after it.
            .onChange(of: showsTour) { _, tour in
                if tour { nav.closePanel() }
            }
    }

    private func sync() {
        waiting?.cancel()
        guard let wanted = nav.panel else {
            // A sheet of the sheet (a speaker's card, a confirmation) goes
            // first, or the two would be torn down out of order.
            if AppNavigation.mainWindow?.attachedSheet?.attachedSheet != nil {
                waiting = Task { @MainActor in
                    while AppNavigation.mainWindow?.attachedSheet?.attachedSheet != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                        if Task.isCancelled { return }
                    }
                    if nav.panel == nil { shown = nil }
                }
            } else {
                shown = nil
            }
            return
        }
        if showsTour {
            // Nothing to land on: drop the link's row too, or it would
            // light up on some later opening of that tab — and say why
            // nothing opened.
            nav.pendingSettingsRow = nil
            nav.pendingConnectionsSection = nil
            nav.closePanel()
            // Not over a toast already saying something (a refused start's
            // warning, which asked for Settings itself).
            if ToastCenter.shared.current == nil {
                ToastCenter.shared.show(String(localized: "settings.afterTour",
                                               defaultValue: "Settings are available after the tour."))
            }
            return
        }
        // Ours is up (Settings ↔ About: SwiftUI closes one and opens the
        // other) or nothing is.
        if shown != nil || AppNavigation.mainWindow?.attachedSheet == nil {
            shown = wanted
            return
        }
        // Another sheet is up — a question, an import, What's New on its
        // way out: wait for it to close.
        waiting = Task { @MainActor in
            guard await SheetQueue.waitUntilClear() else { return }
            if nav.panel == wanted { shown = wanted }
        }
    }

    @ViewBuilder
    private func card(_ panel: MainPanel) -> some View {
        // Fixed, short of the main window by a margin when it is smaller;
        // before the window is measured, the preferred size.
        let window = windowSize.width > 0 && windowSize.height > 0
            ? windowSize : CGSize(width: 10_000, height: 10_000)
        switch panel {
        case .settings:
            SettingsPanel(settings: settings)
                .frame(width: PanelSize.width(SettingsPanel.preferredWidth, in: window.width),
                       height: PanelSize.height(PanelSize.preferredHeight, in: window.height))
                .background(Color.daisyBgPrimary)
        case .about:
            AboutPanel(settings: settings)
                .frame(width: PanelSize.width(AboutPanel.preferredWidth, in: window.width),
                       height: PanelSize.height(PanelSize.preferredHeight, in: window.height))
                .background(Color.daisyBgPrimary)
        }
    }
}

/// Escape and ⌘W in a Settings or About sheet. A local key monitor rather
/// than a `.cancelAction` button, which took Escape from a field being
/// edited. Escape, in order: leaves a Daisy-key command or a shortcut
/// being recorded their Escape (`EscapeWatch`, `KeyCaptureBox`); empties
/// Settings' search; ends the editing of a field; closes the sheet. ⌘W
/// closes it (a sheet has no close button of its own). Keys in a sheet of
/// the sheet, or in any other sheet of the window, are that sheet's; held
/// keys act once.
@MainActor
enum PanelKeys {
    private static var monitor: Any?
    /// The window a Settings or About card is in — only its keys are the
    /// sheet's, never another sheet's while ours waits behind it.
    static weak var sheetWindow: NSWindow?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// True when the key was the sheet's.
    static func handle(_ event: NSEvent) -> Bool {
        let nav = AppNavigation.shared
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let commandW = modifiers == .command && isCommandW(event)
        // A held ⌘W, or a second one while the sheet is still going, must
        // not fall through to Close and take the main window with it.
        if commandW, event.window === sheetWindow || event.window === AppNavigation.mainWindow,
           swallowsCommandW(isRepeat: event.isARepeat, now: ProcessInfo.processInfo.systemUptime) {
            return true
        }
        guard nav.panel != nil, let sheet = sheetWindow, sheet.isVisible,
              event.window === sheet, sheet.attachedSheet == nil else { return false }
        if commandW {
            if !event.isARepeat {
                commandWHeld = true
                nav.closePanel()
            }
            return true
        }
        guard event.keyCode == 53, modifiers.isEmpty else { return false }   // Escape
        if event.isARepeat { return true }
        return escape(
            keyTakenElsewhere: EscapeWatch.isWatching || KeyCaptureBox.isListening,
            editing: sheet.firstResponder is NSText,
            editingSearch: nav.settingsSearchFocused,
            endEditing: { _ = sheet.makeFirstResponder(nil) }
        )
    }

    /// When the sheet last closed (system uptime), and whether the ⌘W
    /// that closed it may still be held.
    private(set) static var closedAt: TimeInterval = -.infinity
    private static var commandWHeld = false

    static func didClose() {
        closedAt = ProcessInfo.processInfo.systemUptime
    }

    /// A ⌘W the sheet keeps although it is gone: the auto-repeat of the
    /// one that closed it, or a fresh one within half a second of closing.
    static func swallowsCommandW(isRepeat: Bool, now: TimeInterval) -> Bool {
        if isRepeat { return commandWHeld }
        // A fresh one this soon is kept — and so are its repeats if held.
        commandWHeld = now - closedAt < 0.5
        return commandWHeld
    }

    /// ⌘W: the letter W, or the W key when the layout types no Latin
    /// letter there (Russian «ц») — not on AZERTY's Z or Dvorak's «,».
    static func isCommandW(_ event: NSEvent) -> Bool {
        isCommandW(keyCode: event.keyCode, character: event.charactersIgnoringModifiers)
    }

    nonisolated static func isCommandW(keyCode: UInt16, character: String?) -> Bool {
        let typed = character?.lowercased() ?? ""
        if typed == "w" { return true }
        let latinOrPunctuation = typed.unicodeScalars.allSatisfy { $0.isASCII }
        return keyCode == 13 && !typed.isEmpty && !latinOrPunctuation
    }

    /// Escape's ladder, apart from AppKit for the tests.
    static func escape(keyTakenElsewhere: Bool, editing: Bool, editingSearch: Bool = false,
                       endEditing: () -> Void) -> Bool {
        let nav = AppNavigation.shared
        if keyTakenElsewhere { return false }
        if !nav.settingsSearch.isEmpty {
            nav.settingsSearch = ""
            return true
        }
        // An empty search field holds the cursor only because AppKit gives
        // a new sheet's focus to it: nothing to let go of — close.
        if editing, !editingSearch {
            endEditing()
            return true
        }
        nav.closePanel()
        return true
    }
}

/// One sheet at a time on the main window. A sheet presented while another
/// is attached makes SwiftUI swap the first out behind its owner's back, so
/// each presenter waits its turn.
@MainActor
enum SheetQueue {
    /// Until the main window has no sheet attached. False when cancelled.
    static func waitUntilClear() async -> Bool {
        while AppNavigation.mainWindow?.attachedSheet != nil {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return false }
        }
        return !Task.isCancelled
    }

    /// Until no Settings or About sheet is asked for or up, then until the
    /// window is clear — for what opens by itself (What's New after an
    /// update, the process-tap question), which must not take the place a
    /// link just asked for.
    static func waitForNoPanel() async -> Bool {
        while AppNavigation.shared.panel != nil {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return false }
        }
        return await waitUntilClear()
    }
}

/// The sheets' size: fixed, short of the window by a margin when the
/// window is smaller (its floor is 860 × 560).
enum PanelSize {
    nonisolated static let preferredHeight: CGFloat = 640
    nonisolated static let margin: CGFloat = 24

    nonisolated static func width(_ preferred: CGFloat, in available: CGFloat) -> CGFloat {
        max(0, min(preferred, available - 2 * margin))
    }

    nonisolated static func height(_ preferred: CGFloat, in available: CGFloat) -> CGFloat {
        max(0, min(preferred, available - 2 * margin))
    }
}

/// A sheet's title and its ×. Escape and ⌘W are `PanelKeys`.
struct PanelHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                AppNavigation.shared.closePanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .daisyHover(Circle())
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 2)

    }
}

/// About: the page alone, no sidebar (Egor 01.11).
struct AboutPanel: View {
    let settings: AppSettings
    nonisolated static let preferredWidth: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: String(localized: "About"))
            AboutView(settings: settings)
                .tint(Color.daisyTextPrimary)
        }
    }
}

struct SettingsPanel: View {
    @Bindable var settings: AppSettings
    @Bindable private var nav = AppNavigation.shared
    /// The search over row titles at the top of the sidebar. Non-empty →
    /// the page gives way to the matching rows (`searchResults`).
    private var searchQuery: String {
        get { nav.settingsSearch }
        nonmutating set { nav.settingsSearch = newValue }
    }
    @FocusState private var searchFocused: Bool

    nonisolated static let sidebarWidth: CGFloat = 210
    nonisolated static let preferredWidth: CGFloat = 900

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                PanelHeader(title: isSearching ? String(localized: "Settings") : nav.settingsTab.title)
                detail
                    // Same ink as the main window's detail pane: plain and
                    // bordered buttons are black and gray, not amber.
                    .tint(Color.daisyTextPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A link to a tab, or a pick in the sidebar, puts the page back in
        // place of a results list.
        .onChange(of: nav.settingsTab) { _, _ in searchQuery = "" }
        .onChange(of: nav.settingsLinkCount) { _, _ in searchQuery = "" }
        // Escape's ladder reads it (PanelKeys).
        .onChange(of: searchFocused, initial: true) { _, focused in nav.settingsSearchFocused = focused }
    }

    // MARK: Sidebar

    /// While searching nothing is selected, so a click on any tab — the
    /// one that was open too — leaves the results.
    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { isSearching ? nil : nav.settingsTab },
            set: { tab in
                guard let tab else { return }
                searchQuery = ""
                nav.settingsTab = tab
            }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                sidebarRow(tab)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.daisyBgSidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .background(Color.daisyBgSidebar)
        }
    }

    /// The main window's sidebar row, drawn the same way (MainView
    /// `sidebarRowBody`): body text, a large symbol in a 24 pt column,
    /// its own rounded selection over an opaque row ground, hover on the
    /// rows that aren't selected.
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = !isSearching && nav.settingsTab == tab
        return HStack(spacing: 10) {
            Image(systemName: tab.systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.body)
                .imageScale(.large)
                .frame(width: 24)
            Text(tab.title)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.daisySidebarInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.daisySidebarSelection : Color.clear)
        )
        .contentShape(Rectangle())
        .daisyHover(isEnabled: !isSelected, overContent: false)
        .listRowBackground(Color.daisyBgSidebar)
        .listRowInsets(EdgeInsets(top: 1, leading: -8, bottom: 1, trailing: -8))
        .tag(tab)
    }

    // MARK: Search (24.10.2026, moved into the sidebar 31.10)

    /// ⌘F anywhere in the sheet puts the cursor here; Escape empties it,
    /// then lets go of it (`PanelKeys`); Return opens the first match.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $nav.settingsSearch)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let first = searchHits.first { openSearchHit(first) }
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        // A hidden button carries the shortcut without needing focus —
        // the Library's delete keys work the same way.
        .background {
            Button("Search settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var searchHits: [SettingsRow] {
        SettingsSearch.results(for: searchQuery, in: SettingsSearch.entries)
    }

    private func openSearchHit(_ row: SettingsRow) {
        searchQuery = ""
        searchFocused = false
        nav.openInSettings(row.tab, row: row)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if isSearching {
            searchResults
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color.daisyBgPrimary)
        } else {
            SettingsView(settings: settings, tab: nav.settingsTab)
        }
    }

    /// The flat list that stands in for the page while searching:
    /// «Row title · Tab», in the order `SettingsSearch` ranks them.
    @ViewBuilder
    private var searchResults: some View {
        let hits = searchHits
        if hits.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing found")
                    .font(.headline)
                Text("Search looks through the names of the settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    ForEach(hits, id: \.self) { row in
                        Button {
                            openSearchHit(row)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: row.tab.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(row.title)
                                Text(verbatim: "·")
                                    .foregroundStyle(.tertiary)
                                Text(row.tab.title)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .daisyHoverRow()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Lends the view's `openWindow` to `AppNavigation`, so code without a
/// SwiftUI environment (links, toasts, notifications, menu items) can
/// bring the main window back once closed — and Settings with it.
struct LendsWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppNavigation.shared.lendWindowOpener(openWindow) }
    }
}
