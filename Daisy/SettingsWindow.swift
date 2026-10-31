//
//  SettingsWindow.swift
//  Daisy
//
//  Settings in a window of their own (Egor, 31.10.2026): «Настройки
//  нужно сделать в окне, которое открывается поверх, и пункты меню
//  настроек должны быть всегда видны в его собственном левом сайдбаре…
//  И „О приложении“ тоже открывать в этом окне поверх».
//
//  Until then Settings and About were pages of the main window, and the
//  eight tabs sat in its toolbar (`ToolbarTabs`). Now:
//   • `Window(id: "settings")` in DaisyApp — one window, opened over the
//     main one by «Daisy → Settings…» ⌘,, «About Daisy», the main
//     sidebar's two bottom rows, the menu bar and the widget, and every
//     `AppNavigation.openInSettings(_:row:)` link.
//   • Its sidebar lists the eight tabs of the 2026-10-23 structure and,
//     under them, About — always shown: no sidebar button, no collapse.
//   • The search over row titles sits at the top of that sidebar; its
//     hits replace the page while it has text.
//
//  A window rather than a sheet: a sheet is modal to the main window and
//  needs it open, while the links come from notifications, the widget
//  and the menu bar when it often is not; and Settings' own sheets,
//  alerts and file pickers would stack on top of it.
//

import AppKit
import SwiftUI

/// A page of the Settings window: one of the eight tabs, or About.
enum SettingsPane: Hashable, Sendable {
    case tab(SettingsTab)
    case about

    /// Sidebar order: the tabs, then About on its own below them.
    static let tabs: [SettingsPane] = SettingsTab.allCases.map { .tab($0) }

    var title: String {
        switch self {
        case .tab(let tab): tab.title
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .tab(let tab): tab.systemImage
        case .about: "info.circle"
        }
    }
}

enum SettingsWindow {
    /// The `Window` scene's id (DaisyApp).
    static let id = "settings"
    /// Sidebar plus the narrowest page Settings lays out well (640 pt).
    static let sidebarWidth: CGFloat = 220
    static let minWidth: CGFloat = 860
    static let minHeight: CGFloat = 560
}

struct SettingsWindowView: View {
    @Bindable var settings: AppSettings
    @Bindable private var nav = AppNavigation.shared
    /// The search over row titles at the top of the sidebar. Non-empty →
    /// the page gives way to the matching rows (`searchResults`).
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    /// Pinned to `.all`: anything that folds the sidebar is undone.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                // The sections are always in view (Egor): no button
                // folds the sidebar away, and it has one width — the
                // longest title («Подключения») whole, at any window size.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(SettingsWindow.sidebarWidth)
        } detail: {
            detail
                // Same ink as the main window's detail pane: plain and
                // bordered buttons are black and gray, not amber.
                .tint(Color.daisyTextPrimary)
        }
        .navigationTitle(isSearching ? String(localized: "Settings") : nav.settingsPane.title)
        .frame(minWidth: SettingsWindow.minWidth, minHeight: SettingsWindow.minHeight)
        .modifier(ToastOverlay())
        .background(WindowFinder { window in
            // Opened on demand, never brought back by a relaunch, and
            // never a tab of the main window.
            window?.isRestorable = false
            window?.tabbingMode = .disallowed
        })
        .modifier(LendsWindowOpener())
        // A link to a page, or a pick in the sidebar, puts the page back
        // in place of a results list.
        .onChange(of: nav.settingsPane) { _, _ in searchQuery = "" }
        .onChange(of: nav.settingsLinkCount) { _, _ in searchQuery = "" }
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all { columnVisibility = .all }
        }
    }

    // MARK: Sidebar

    /// While searching nothing is selected, so a click on any page —
    /// the one that was open too — leaves the results.
    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { isSearching ? nil : nav.settingsPane },
            set: { pane in
                guard let pane else { return }
                searchQuery = ""
                nav.settingsPane = pane
            }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                ForEach(SettingsPane.tabs, id: \.self) { pane in
                    sidebarRow(pane)
                }
            }
            // About under the tabs, a little apart: it is about the app,
            // not a setting.
            Section {
                sidebarRow(.about)
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
    private func sidebarRow(_ pane: SettingsPane) -> some View {
        let isSelected = !isSearching && nav.settingsPane == pane
        return HStack(spacing: 10) {
            Image(systemName: pane.systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.body)
                .imageScale(.large)
                .frame(width: 24)
            Text(pane.title)
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
        .tag(pane)
    }

    // MARK: Search (24.10.2026, moved into the sidebar 31.10)

    /// ⌘F anywhere in the window puts the cursor here; Escape empties it
    /// (then lets go); Return opens the first match.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let first = searchHits.first { openSearchHit(first) }
                }
                // `onExitCommand` alone does not reach a focused plain
                // field (same finding as the Library's rename field).
                .onKeyPress(.escape) {
                    if searchQuery.isEmpty {
                        searchFocused = false
                    } else {
                        searchQuery = ""
                    }
                    return .handled
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
            switch nav.settingsPane {
            case .tab(let tab):
                SettingsView(settings: settings, tab: tab)
            case .about:
                AboutView(settings: settings)
            }
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
/// open the Settings window or bring the main one back once closed.
struct LendsWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppNavigation.shared.lendWindowOpener(openWindow) }
    }
}
