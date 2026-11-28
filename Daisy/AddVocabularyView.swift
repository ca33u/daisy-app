// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  AddVocabularyView.swift
//  Daisy
//
//  Modal sheet for adding or editing one dictation-vocabulary entry,
//  modelled on Wispr Flow's "Add to vocabulary" dialog. One toggle picks
//  the entry's flavour:
//
//    • OFF (default) — "Add a new word": a `.term`. You're teaching Daisy
//      a custom word (name, brand, jargon). Daisy fixes its spelling/casing
//      on output and, on Whisper, biases recognition toward it.
//    • ON — "Correct a misspelling": a `.correction` rule. A `Misspelling
//      → Correct spelling` pair Daisy swaps whenever the misheard version
//      is dictated. (This is the historical dictionary behaviour.)
//
//  "Share with team" from Wispr's dialog is intentionally omitted — Daisy
//  is local-first and single-user, so there's no team to sync to. (A vault
//  export/import could fill that role later.)
//
//  The view writes straight to `DictationDictionary.shared`; the caller
//  just presents it as a `.sheet`.
//

import SwiftUI

struct AddVocabularyView: View {
    @Environment(\.dismiss) private var dismiss

    private let dictionary = DictationDictionary.shared

    /// nil → adding a new entry; non-nil → editing this existing one.
    let editing: DictationReplacement?

    /// True = correction rule (two fields); false = a plain term (one field).
    @State private var isCorrection: Bool
    /// Term word, or — in correction mode — the "Correct spelling" target.
    @State private var word: String
    /// Correction-mode "Misspelling" source. Unused for a term.
    @State private var misspelling: String
    @FocusState private var firstFieldFocused: Bool

    init(editing: DictationReplacement? = nil) {
        self.editing = editing
        if let editing {
            _isCorrection = State(initialValue: editing.kind == .correction)
            _word = State(initialValue: editing.to)
            _misspelling = State(initialValue: editing.from)
        } else {
            _isCorrection = State(initialValue: false)
            _word = State(initialValue: "")
            _misspelling = State(initialValue: "")
        }
    }

    private var trimmedWord: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedMisspelling: String {
        misspelling.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Add/Save is enabled only with the fields the chosen mode needs.
    private var canSave: Bool {
        if isCorrection {
            return !trimmedWord.isEmpty && !trimmedMisspelling.isEmpty
        }
        return !trimmedWord.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editing == nil ? "Add to vocabulary" : "Edit vocabulary")
                .font(.title3.weight(.semibold))

            if isCorrection {
                HStack(spacing: 10) {
                    TextField("Misspelling", text: $misspelling)
                        .textFieldStyle(.roundedBorder)
                        .focused($firstFieldFocused)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Correct spelling", text: $word)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                TextField("Add a new word", text: $word)
                    .textFieldStyle(.roundedBorder)
                    .focused($firstFieldFocused)
            }

            HStack(spacing: 10) {
                // "Correct a misspelling" moved down to the button row,
                // left-aligned (Egor 2026-06-16), as a SWITCH (not the
                // default macOS checkbox).
                Toggle(isOn: $isCorrection.animation(.easeInOut(duration: 0.15))) {
                    HStack(spacing: 6) {
                        Text("Correct a misspelling")
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("On: turns this into a correction rule — Daisy replaces the misheard version with your spelling whenever it's dictated. Off: just teaches Daisy a new word so it spells and capitalises it correctly (and, on Whisper, hears it better).")
                    }
                }
                .toggleStyle(.switch)

                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add word" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyTextPrimary)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { firstFieldFocused = true }
    }

    private func save() {
        guard canSave else { return }
        var entry = editing ?? DictationReplacement()
        if isCorrection {
            entry.kind = .correction
            entry.from = trimmedMisspelling
            entry.to = trimmedWord
        } else {
            entry.kind = .term
            entry.from = ""
            entry.to = trimmedWord
        }
        if editing == nil {
            dictionary.add(entry)
        } else {
            dictionary.update(entry)
        }
        dismiss()
    }
}

#Preview("Add") {
    AddVocabularyView()
}

#Preview("Edit correction") {
    AddVocabularyView(editing: DictationReplacement(kind: .correction, from: "clod", to: "Claude"))
}
