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
        // Custom text-only Liquid-Glass tab strip in the window toolbar
        // (ToolbarItem .principal below), replacing the native TabView
        // whose per-cell padding is system-locked. `selection:` keeps the
        // active tab stable and lets external surfaces deep-link.
        Group {
            switch tab {
            case .vocabulary: vocabularyTab
            case .history:    historyTab
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
            // Text-only glass tab strip, centered at toolbar level.
            ToolbarItem(placement: .principal) {
                GlassSegmentedControl(
                    selection: $tab,
                    segments: [
                        .init(value: .vocabulary, title: String(localized: "Vocabulary")),
                        .init(value: .history, title: String(localized: "History")),
                    ]
                )
            }
            // Bulk import — vocabulary tab only (nothing to import into
            // History). Sits left of "Add word".
            if tab == .vocabulary {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportVocabulary()
                    } label: {
                        Text("Export vocabulary")
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
                        .padding(.horizontal, 10)
                }
                .help("Add a word to your dictation vocabulary")
            }
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
