// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DictationDictionaryView.swift
//  Daisy
//
//  Editor for the dictation vocabulary (`DictationDictionary`). Lists each
//  entry — a taught word (`.term`) or a `heard → replacement` correction —
//  with per-row edit/delete, and an "Add word" button that presents the
//  Wispr-style `AddVocabularyView` modal.
//
//  Embedding contract: this view renders ONLY rows + controls — no `Form`,
//  no `Section` of its own. The caller drops it inside a Settings
//  `Form { Section { … } }` (today: the sidebar "Dictation" page →
//  "Vocabulary" section).
//
//  Styling mirrors the other Settings rows (callout-weight titles,
//  `.bordered`/`.borderless` buttons, `Color.daisy*` tokens) so it sits
//  seamlessly next to the speaker-profile and storage rows.
//

import SwiftUI

struct DictationDictionaryView: View {
    /// The shared store. `@Bindable` so add/edit/delete drive observation
    /// and re-render the list in place.
    @Bindable private var dictionary = DictationDictionary.shared

    /// Non-nil presents the edit modal for that entry (`.sheet(item:)`).
    @State private var editingEntry: DictationReplacement?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One-line explainer in Daisy's plain voice — names both
            // flavours so the Add modal's toggle reads as expected.
            Text("Teach Daisy your words. A word fixes spelling and casing (and, on Whisper, helps it be heard); a correction replaces something Daisy mishears.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if dictionary.replacements.isEmpty {
                emptyState
            } else {
                rows
            }
        }
        .sheet(item: $editingEntry) { entry in
            AddVocabularyView(editing: entry)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
            Text("No words yet.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(dictionary.replacements) { entry in
                row(for: entry)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: DictationReplacement) -> some View {
        HStack(spacing: 8) {
            // Leading glyph distinguishes a taught word from a correction
            // rule at a glance.
            Image(systemName: entry.kind == .term ? "text.book.closed" : "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            entryLabel(entry)

            Spacer(minLength: 8)

            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.daisyTextPrimary)
            }
            .buttonStyle(.plain)
            .help("Edit")

            // Per-row delete — borderless destructive glyph, distinct hit
            // target from the edit button. Matches the "Forget" idiom in
            // the speaker list (a compact glyph keeps the row narrow).
            Button {
                dictionary.remove(entry)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Color.daisyTextPrimary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editingEntry = entry }
    }

    /// The content half of a row: the word, or `heard → replacement`.
    @ViewBuilder
    private func entryLabel(_ entry: DictationReplacement) -> some View {
        switch entry.kind {
        case .term:
            Text(entry.to.isEmpty ? "—" : entry.to)
        case .correction:
            HStack(spacing: 6) {
                Text(entry.from.isEmpty ? "—" : entry.from)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(entry.to.isEmpty ? "—" : entry.to)
            }
        }
    }

}
