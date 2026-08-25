//
//  BulkDeleteRecordingsView.swift
//  Daisy
//
//  A self-contained "delete recordings in bulk" control, designed to
//  be dropped INTO an existing Settings `Form` → `Section` (it renders
//  bare controls — a scope Picker, a live count, and a destructive
//  Delete button — NOT its own Form). Wired into Settings → General →
//  Storage next to "Clear all audio now".
//
//  Scope is either every recording in the library, or every recording
//  in one folder (`FolderStore.shared.allFolders`). Confirmation lives
//  in a `.confirmationDialog`, mirroring the tone/structure of the
//  "Clear all audio now" flow in SettingsView — the destructive red
//  surfaces in the confirm, not on the row trigger.
//
//  The actual deletion runs through `SessionStore`'s bulk-delete
//  methods, which skip the in-progress recording and refresh the store
//  once at the end:
//      • all folders  → SessionStore.deleteAllSessions()
//      • one folder   → SessionStore.deleteSessions(inFolder:)
//  The count shown is `deletableSessionCount(inFolder:)`, which applies
//  the SAME filtering (folder + active-recording skip), so the confirm
//  promises the true number that will be removed.
//

import SwiftUI

struct BulkDeleteRecordingsView: View {
    /// Called once a bulk delete has finished. The host Settings screen
    /// uses it to re-measure the "Space used" row — this control is the
    /// biggest single mover of that number, and nothing else would tell
    /// the row it changed while the window stays open.
    var onDeleted: (@MainActor () -> Void)?

    /// Bind to the singletons so the count + folder list re-render
    /// reactively as sessions are added/removed and folders change.
    @Bindable private var store = SessionStore.shared
    @Bindable private var folders = FolderStore.shared

    /// Bulk-delete scope. `.all` removes everything; `.folder(slug)`
    /// scopes to one folder. We key the folder case on the slug (a
    /// plain String) rather than the `SessionFolder` value so the
    /// selection survives a folder-list reorder and so the Picker tag
    /// type stays trivially `Hashable`.
    private enum Scope: Hashable {
        case all
        case folder(slug: String)
    }

    @State private var scope: Scope = .all
    /// Drives the destructive confirmation dialog.
    @State private var showingConfirm = false
    /// Set while a delete is in flight so the button shows progress and
    /// can't be double-fired.
    @State private var deleting = false

    var body: some View {
        let count = deletableCount

        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Title weight matches the sibling Storage rows
                // ("Clear all audio now", "Recordings folder").
                Text("Delete recordings")
                    .font(.callout.weight(.medium))
                Text(countCaption(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Scope picker — "All recordings" or a specific folder.
            // .menu style to match every other Picker in Settings.
            Picker("", selection: $scope) {
                Text("All recordings").tag(Scope.all)
                Divider()
                ForEach(folders.allFolders) { folder in
                    Text(folder.name).tag(Scope.folder(slug: folder.slug))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(deleting)

            // Destructive trigger. Same pattern as the "Clear all audio
            // now" row: explicit red tint ONLY when there's something to
            // delete (a `role: .destructive` button renders a muddy
            // disabled peach on the cream surface and overrides `.tint`),
            // secondary grey when the scope is empty. The destructive
            // intent is surfaced inside the confirm dialog, where it
            // belongs. No trailing ellipsis on the label even though a
            // confirm follows — a y/n confirm isn't "more input" per the
            // macOS HIG, so the dot would be noise.
            Button {
                showingConfirm = true
            } label: {
                if deleting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Delete")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(count == 0 ? Color.secondary : Color.daisyError)
            .disabled(deleting || count == 0)
        }
        // confirmationDialog so the destructive action gets a red,
        // clearly-labelled confirm button. Title carries the count;
        // the message spells out exactly what's removed and that it's
        // irreversible — same structure as the audio-cache confirm.
        .confirmationDialog(
            confirmTitle(count),
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            Button(confirmButtonLabel(count), role: .destructive) {
                runDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the audio, transcript, summary and screenshots from disk and can't be undone.")
        }
    }

    // MARK: - Derived state

    /// Number of sessions the current scope would delete — already
    /// excludes the in-progress recording (the store applies that skip).
    private var deletableCount: Int {
        switch scope {
        case .all:
            return store.deletableSessionCount()
        case .folder(let slug):
            return store.deletableSessionCount(inFolder: slug)
        }
    }

    /// Human label for the currently-selected folder, for captions and
    /// the confirm copy. Falls back to the raw slug if the folder was
    /// removed out from under the selection (shouldn't happen via the
    /// Picker, but keeps the strings sane if it does).
    private var scopeFolderName: String? {
        guard case .folder(let slug) = scope else { return nil }
        return folders.allFolders.first(where: { $0.slug == slug })?.name ?? slug
    }

    // MARK: - Copy

    /// Caption under the row title — reflects scope + live count.
    private func countCaption(_ count: Int) -> String {
        if count == 0 {
            if let folder = scopeFolderName {
                return String(localized: "No recordings in \(folder)")
            }
            return String(localized: "No recordings to delete")
        }
        if let folder = scopeFolderName {
            return String(localized: "\(count) recordings in \(folder)")
        }
        return String(localized: "\(count) recordings across all projects")
    }

    /// Confirmation dialog title — leads with the count, names the
    /// folder when scoped so the user can't mistake which set they're
    /// about to wipe.
    private func confirmTitle(_ count: Int) -> String {
        if let folder = scopeFolderName {
            return String(localized: "Delete \(count) recordings in \(folder)?")
        }
        return String(localized: "Delete \(count) recordings?")
    }

    /// Red confirm-button label. Echoes the count so the destructive
    /// action restates exactly what it'll do at the moment of commit.
    private func confirmButtonLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "Delete 1 recording") : String(localized: "Delete \(count) recordings")
    }

    // MARK: - Action

    private func runDelete() {
        deleting = true
        let target = scope
        Task {
            switch target {
            case .all:
                await store.deleteAllSessions()
            case .folder(let slug):
                await store.deleteSessions(inFolder: slug)
            }
            deleting = false
            onDeleted?()
        }
    }
}
