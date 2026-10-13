//
//  DictationHistoryView.swift
//  Daisy
//
//  Read-only list of the user's recent dictations (`DictationHistory`),
//  shown in the Dictation window's History tab. Each row is the dictated
//  text plus a relative timestamp; tapping a row re-copies that text to
//  the clipboard. On top: how long the history is kept, said in words
//  and changeable right there — a list that empties itself without
//  saying so reads as data lost (2026-10-13). Shortening the window asks
//  before older dictations go.
//
//  Embedding contract: this view renders ONLY rows + controls — no
//  `Form`, no `Section` of its own. The caller is expected to drop it
//  inside a Settings `Form { Section { … } }` (e.g. a "Dictation" tab),
//  exactly like its sibling `DictationDictionaryView`:
//
//      Section {
//          DictationHistoryView()
//      } header: {
//          Text("Recent dictations")
//      }
//
//  Styling mirrors `DictationDictionaryView` and the other Settings rows
//  (caption helper text, callout-weight body, `.bordered`/`.small`
//  buttons, `Color.daisy*` tokens, `ToastCenter` for the copy toast) so
//  it sits seamlessly next to the dictionary editor.
//

import AppKit
import SwiftUI

struct DictationHistoryView: View {
    /// The shared store. `@Bindable` keeps the list in sync as entries are
    /// recorded (while Settings is open) or cleared.
    @Bindable private var history = DictationHistory.shared

    /// A shorter window waiting for "Delete" in the confirmation.
    @State private var pendingRetention: DictationRetention?
    /// What the open question is about. Kept after the answer, so the
    /// title doesn't go blank while the dialog animates away.
    @State private var askedRetention: DictationRetention = .default

    /// Relative-time formatter for the per-row timestamp ("3 minutes
    /// ago"). Held once rather than rebuilt per row.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        // Each piece is its own row of the caller's Form section: the
        // header, then one row per dictation — so a list of 2,000 is
        // built as it scrolls, not all at once.
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Keep dictation history", selection: Binding(
                    get: { history.retention },
                    set: { choose($0) }
                )) {
                    ForEach(DictationRetention.allCases) { option in
                        Text(Self.label(for: option)).tag(option)
                    }
                }
                .pickerStyle(.menu)

                // Says how long, in words: a list that empties itself
                // without saying so reads as data lost.
                Text(Self.explanation(for: history.retention))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { history.sweepExpired() }
            .confirmationDialog(
                Self.deleteQuestion(keeping: askedRetention),
                isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let new = pendingRetention { history.setRetention(new) }
                    pendingRetention = nil
                }
                Button("Cancel", role: .cancel) { pendingRetention = nil }
            } message: {
                Text("Dictations to delete: \(history.entriesRemoved(by: askedRetention))")
            }

            if history.entries.isEmpty {
                emptyState
            } else {
                ForEach(history.entries) { entry in
                    row(for: entry)
                }
            }
        }
    }

    // MARK: - Retention

    /// A longer window applies at once; a shorter one that would remove
    /// dictations asks first, and Cancel keeps the old window.
    private func choose(_ new: DictationRetention) {
        if history.entriesRemoved(by: new) > 0 {
            askedRetention = new
            pendingRetention = new
        } else {
            history.setRetention(new)
        }
    }

    nonisolated static func label(for retention: DictationRetention) -> String {
        switch retention {
        case .day: return String(localized: "24 hours")
        case .week: return String(localized: "7 days")
        case .month: return String(localized: "30 days")
        case .always: return String(localized: "Always")
        }
    }

    nonisolated static func explanation(for retention: DictationRetention) -> String {
        switch retention {
        case .day: return String(localized: "Kept on your Mac for 24 hours, then deleted. Click to copy.")
        case .week: return String(localized: "Kept on your Mac for 7 days, then deleted. Click to copy.")
        case .month: return String(localized: "Kept on your Mac for 30 days, then deleted. Click to copy.")
        case .always: return String(localized: "Kept on your Mac until you clear it — the latest 2,000 dictations. Click to copy.")
        }
    }

    nonisolated static func deleteQuestion(keeping retention: DictationRetention) -> String {
        switch retention {
        case .day: return String(localized: "Delete dictations older than 24 hours?")
        case .week: return String(localized: "Delete dictations older than 7 days?")
        case .month: return String(localized: "Delete dictations older than 30 days?")
        case .always: return ""   // never shorter than anything
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        // Mirrors `DictationDictionaryView.emptyState` — icon + secondary
        // line, left-aligned — so the two dictation surfaces feel like
        // siblings.
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Text(Self.emptyText(for: history.retention))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }

    nonisolated static func emptyText(for retention: DictationRetention) -> String {
        switch retention {
        case .day: return String(localized: "Nothing in the last 24 hours.")
        case .week: return String(localized: "Nothing in the last 7 days.")
        case .month: return String(localized: "Nothing in the last 30 days.")
        case .always: return String(localized: "No dictations yet.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for entry: DictationEntry) -> some View {
        Button {
            copy(entry)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.callout)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())   // whole row is the hit target
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    // MARK: - Copy

    /// Re-copy a recorded dictation to the clipboard and confirm with a
    /// toast. Writes plain text only — the same string `DictationPaste`
    /// originally placed there.
    private func copy(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        ToastCenter.shared.show(String(localized: "Copied"), style: .success)
    }
}
