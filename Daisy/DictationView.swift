//
//  DictationView.swift
//  Daisy
//
//  Top-level sidebar page for the dictation user — a focused home for
//  the word-replacement dictionary and the rolling 24-hour history.
//  Promoted out of the Settings "Dictation" tab in 1.0.7.19 so it sits
//  alongside Home / Library / Connections in the sidebar.
//
//  Split into two tabs (Egor 2026-06-16) — "Vocabulary" and "History".
//  Uses a native `TabView` with `.tabItem` chrome to match Settings
//  (replaced the `.segmented` Picker 2026-06-24). Each tab is a
//  `Form { Section { … } }` whose child view (`DictationDictionaryView`
//  / `DictationHistoryView`) renders rows only. "Add word" lives in the
//  window toolbar (top-right) on BOTH tabs; "Clear history" in the
//  History tab's header.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DictationView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case vocabulary = "Vocabulary"
        case history = "History"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .vocabulary
    /// The two tabs as the toolbar's own tab control (see ToolbarTabs):
    /// a custom glass strip in the toolbar vanishes into «>>» in a narrow
    /// window, the system's folds into a pop-up (26.09, as Settings).
    @State private var toolbarTabs = ToolbarTabs(identifier: "app.essazanov.Daisy.dictationTabs")
    /// See SettingsView: installing vs. refused after every retry.
    @State private var toolbarTabsInstalled = false
    @State private var toolbarTabsFailed = false
    private static let tabOrder: [Tab] = [.vocabulary, .history]
    @State private var showingAddWord = false
    @State private var showingBulkImport = false

    /// One text file, in the same shape Bulk import reads — so the
    /// vocabulary can move to another Mac or into a teammate's Daisy.
    private func exportVocabulary() {
        let entries = DictationDictionary.shared.replacements
        guard !entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Daisy vocabulary.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DictationDictionary.exportText(entries).write(to: url, atomically: true, encoding: .utf8)
            ToastCenter.shared.show(
                String(localized: "Exported \(entries.count) vocabulary entries"),
                style: .success
            )
        } catch {
            ToastCenter.shared.show(error.localizedDescription, style: .error)
        }
    }
    // Observe history so the "Clear history" capsule appears / disappears
    // as entries are recorded or cleared.
    @Bindable private var history = DictationHistory.shared

    var body: some View {
        // The tabs are the toolbar's own tab control (toolbarTabs); only
        // if the toolbar will not keep it do they show above the page.
        VStack(spacing: 12) {
            if toolbarTabsFailed {
                Picker("Dictation", selection: $tab) {
                    Text("Vocabulary").tag(Tab.vocabulary)
                    Text("History").tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 12)
            }
            Group {
                switch tab {
                case .vocabulary: vocabularyTab
                case .history:    historyTab
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.daisyBgPrimary)
        .sheet(isPresented: $showingAddWord) {
            AddVocabularyView()
        }
        .sheet(isPresented: $showingBulkImport) {
            BulkImportVocabularyView()
        }
        .toolbar {
            // Bulk import — vocabulary tab only (nothing to import into
            // History). Sits left of "Add word".
            if tab == .vocabulary {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportVocabulary()
                    } label: {
                        Text("Export vocabulary")
                            .fontWeight(.regular)
                            .padding(.horizontal, 10)
                    }
                    .disabled(DictationDictionary.shared.replacements.isEmpty)
                    .help("Save the vocabulary as a text file Daisy can import again")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingBulkImport = true
                    } label: {
                        Text("Bulk import")
                            .fontWeight(.regular)
                            .padding(.horizontal, 10)
                    }
                    .help("Paste a list or import a file of words / corrections")
                }
            }
            // "Add word" in the window toolbar top-right (like the Library
            // "Summarize" pill). Shown on BOTH tabs so the affordance
            // never disappears (Egor 2026-06-24).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddWord = true
                } label: {
                    Text("Add word")
                        // Regular, like the tab titles beside them —
                        // a toolbar text button is semibold by default.
                        .fontWeight(.regular)
                        .padding(.horizontal, 10)
                }
                .help("Add a word to your dictation vocabulary")
            }
        }
        .background(WindowFinder { window in
            guard let window, !toolbarTabsInstalled else { return }
            toolbarTabs.onSelect = { index in
                if Self.tabOrder.indices.contains(index) { tab = Self.tabOrder[index] }
            }
            toolbarTabs.onLost = { toolbarTabsFailed = true }
            toolbarTabsInstalled = true
            toolbarTabs.installRetrying(
                in: window,
                titles: [String(localized: "Vocabulary"), String(localized: "History")],
                selected: { Self.tabOrder.firstIndex(of: tab) ?? 0 }
            ) { ok in toolbarTabsFailed = !ok }
        })
        .onChange(of: tab) { _, new in toolbarTabs.select(Self.tabOrder.firstIndex(of: new) ?? 0) }
        .onDisappear {
            toolbarTabs.uninstall()
            toolbarTabsInstalled = false
            toolbarTabsFailed = false
        }
    }

    // MARK: - Tabs

    private var vocabularyTab: some View {
        Form {
            Section {
                DictationDictionaryView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var historyTab: some View {
        Form {
            Section {
                DictationHistoryView()
            } header: {
                HStack {
                    Text("Recent dictations")
                    Spacer()
                    if !history.entries.isEmpty {
                        clearHistoryButton
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var clearHistoryButton: some View {
        // Neutral, not destructive-red — clearing a rolling 24h history is
        // low-stakes (it auto-clears anyway), so the red read as too alarming.
        Button {
            DictationHistory.shared.clear()
            ToastCenter.shared.show(String(localized: "History cleared"), style: .success)
        } label: {
            Label("Clear history", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .tint(.secondary)
        .textCase(nil)
    }
}
