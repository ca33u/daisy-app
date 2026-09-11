//
//  LibraryView.swift
//  Daisy
//
//  Browser for past recording sessions. As of 2026-07-21 the Library is
//  rendered by MainView as a GENUINE three-column NavigationSplitView:
//      [sidebar/section-nav] | [session list] | [session detail]
//  so the window's Liquid Glass toolbar splits into column-aligned
//  sections (Daisy pill over the sidebar, Tags pill over the list,
//  Add-tag / Summarize / ⋯ over the detail). To make a list column and
//  a detail column — two separate view trees — share one selection, the
//  former per-view `@State` (selection / query / filters / pending
//  delete) is hoisted into `LibraryModel`, an `@Observable` owned by
//  MainView (one instance; the kind filter lives inside the model).
//
//  `LibraryListColumn` and `LibraryDetailColumn` are the two column
//  views MainView places in `content:` and `detail:`. `LibraryView`
//  remains as a thin composite (list | divider | detail in an HStack)
//  for #Preview and as a non-split fallback; MainView no longer renders
//  it for the live Library/Notes tabs.
//
//  Sidebar entry is called "Library" — `HistoryView` was the original
//  name when it framed the section as a chronological log; renamed
//  2026-05-19 alongside the shift to a curated-collection mental model
//  (Granola / Cleft / Apple Books / Music pattern).
//

import SwiftUI
import AppKit

// MARK: - Scope

/// Which kinds the Library shows. Since 2026-09-07 this is a FILTER the
/// person flips inside one Library (a chip row above the list), not two
/// sidebar tabs: notes and recordings were always the same model, the
/// same folders and tags, the same on-disk files — told apart by one
/// field, `kind` — and two entries in the sidebar made them look like
/// two products (Egor). `.all` is the default and shows everything;
/// `.recordings` and `.notes` narrow by kind. Nothing on disk changes.
///
/// `LibraryView.Scope` stays as a typealias for source compatibility.
enum LibraryScope: String, Equatable, CaseIterable, Identifiable {
    case all, recordings, notes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        String(localized: "All")
        case .recordings: String(localized: "Recordings")
        case .notes:      String(localized: "Notes")
        }
    }
}

// MARK: - Shared selection model

/// The Library's cross-column state. In the three-column shell the list
/// (content column) and the detail (detail column) are separate view
/// trees, so their shared selection can't live in either's `@State` —
/// it's hoisted here and handed to both columns by MainView, which owns
/// the instance (`@State`) so the state survives the split's remount
/// when the user navigates away and back.
///
/// Nothing here is persisted: kind, project, tag and query all start
/// unfiltered on relaunch, so a filter set last week can never hide
/// today's recordings from someone who forgot about it.
@Observable
@MainActor
final class LibraryModel {
    /// Kind filter — see `LibraryScope`. Mutable: it's a chip now.
    var scope: LibraryScope
    var query: String = ""
    /// Selected session IDs. Multi-select via Shift-click (range)
    /// and Cmd-click (toggle). When exactly one is selected, the
    /// detail pane shows it. When several, the pane shows a "N
    /// selected" empty-state with a bulk-delete CTA.
    var selectedIDs: Set<StoredSession.ID> = []
    /// Active folder filter. `nil` = show all folders.
    var folderFilter: SessionFolder? = nil
    /// Active tag filter. `nil` == "all tags" (no filter). `.some("")`
    /// == "untagged" bucket only. `.some("Mediacube")` == that exact
    /// tag. Driven by the selector pill in the list column's toolbar.
    var tagFilter: String? = nil
    /// Pending delete confirmation. Carries the sessions about to
    /// be removed (1 for context-menu, N for multi-select).
    var pendingDelete: [StoredSession] = []
    /// IDs the list is actually showing right now, published by the list
    /// column on every filter change.
    ///
    /// `selectedIDs` deliberately survives a filter change — you can
    /// narrow the list without losing your place. That makes every bulk
    /// action a hazard, because the selection can name rows that are no
    /// longer on screen, and Delete removes audio, transcript, summary
    /// and screenshots for good. So every bulk action resolves through
    /// `visibleSelection` instead. Staleness is safe in one direction
    /// only: a lagging set can under-include (the action does less than
    /// asked), never over-include.
    var visibleIDs: Set<StoredSession.ID> = []

    init(scope: LibraryScope) { self.scope = scope }

    /// The selection narrowed to what the user can see. The one way any
    /// bulk action should resolve `selectedIDs` into sessions.
    func visibleSelection(in pool: [StoredSession]) -> [StoredSession] {
        pool.filter { selectedIDs.contains($0.id) && visibleIDs.contains($0.id) }
    }

    /// How many rows a bulk action would actually touch. Labels and
    /// counts read this so the number matches the deed.
    var visibleSelectionCount: Int {
        selectedIDs.intersection(visibleIDs).count
    }

    /// Single selected session, used as a derived view for the detail
    /// pane. `nil` when 0 or >1 selected. Reads `SessionStore` so the
    /// detail column re-renders when the store swaps the row in-place
    /// (post-Stop summary write).
    var singleSelected: StoredSession? {
        guard selectedIDs.count == 1,
              let id = selectedIDs.first else { return nil }
        return SessionStore.shared.sessions.first(where: { $0.id == id })
    }
}

// MARK: - List column (content column of the split)

/// The session list: search header, folder chips, the list itself, the
/// Tags-filter toolbar pill, bulk-delete keyboard shortcuts + alert, and
/// the deep-link / default-selection wiring. Lives in the split's
/// `content:` column; its `.toolbar` items therefore land in the list
/// region of the window toolbar (Tags pill pinned to that region's
/// trailing edge). All selection/filter state is in the shared `model`.
struct LibraryListColumn: View {
    @Bindable var model: LibraryModel
    @Bindable var store = SessionStore.shared
    @Bindable var folders = FolderStore.shared
    @State private var isImportTargeted = false
    @State private var pendingImport: AudioImportBatch?
    private var importRunner: AudioImportRunner { .shared }

    private var scope: LibraryScope { model.scope }

    /// "Transcribing 2 of 5 · acme — Loading the selected model": the
    /// batch position plus what the audio pipeline is doing right now
    /// (a model download can take minutes).
    private var importRunnerLine: String? {
        if importRunner.isRunning {
            let inner = SessionAudioProcessing.shared.statusText
            return inner.isEmpty ? importRunner.statusText : "\(importRunner.statusText) — \(inner)"
        }
        return ImportTranscriptionQueue.shared.statusLine
    }

    /// Finder drop → the import dialog (AudioImportSheet). Unsupported
    /// files are not filtered here: the dialog lists them with a reason
    /// (design §6.8). Returns whether the drop was accepted at all —
    /// Finder animates a rejected drop back to its origin.
    private func importDroppedFiles(_ urls: [URL]) -> Bool {
        guard !AudioImportRunner.shared.isRunning else {
            ToastCenter.shared.show(
                String(localized: "An import is already running. Drop the files again when it finishes."),
                style: .warning
            )
            return false
        }
        guard !urls.isEmpty else { return false }
        // Imports are recordings, so under the Notes chip the new rows
        // would land outside the filter. Rejecting the drop was worse:
        // Finder just animates the files back with no explanation, and
        // Notes is now one chip away in the same row as the projects,
        // so you can be sitting on it without meaning to. Step aside to
        // All instead — same thing `consumePendingImport` does.
        //
        // Read the destination project BEFORE stepping aside:
        // `selectKind` clears `folderFilter`, and taking the slug after
        // it would quietly import into no project at all.
        let destination = model.folderFilter?.slug
        if scope == .notes { selectKind(.all) }
        // Folders are expanded by the dialog (AudioImporter.expand):
        // each becomes a project of its own name.
        pendingImport = AudioImportBatch(urls: urls, folderSlug: destination)
        return true
    }

    var body: some View {
        sessionList
            // Publish what's on screen so bulk actions — including the
            // ones in the detail column, which can't see this list —
            // can never touch a row a filter is hiding. Keyed on the
            // IDs rather than the sessions so an in-place row rewrite
            // (the post-Stop summary write) doesn't churn it.
            .onChange(of: filteredSessions.map(\.id), initial: true) { _, ids in
                model.visibleIDs = Set(ids)
            }
            // List column paper tone (Home surface), NOT the frosted
            // content-column material a NavigationSplitView paints by
            // default. `.scrollContentBackground(.hidden)` on the inner
            // List (below) lets this show through.
            .background(Color.daisyBgPrimary)
            // Drop audio files from Finder → imported as audio-only
            // sessions (AudioImporter, design 2026-08-31 Ф0). The
            // active project chip becomes the session's project.
            .dropDestination(for: URL.self) { urls, _ in
                importDroppedFiles(urls)
            } isTargeted: { targeted in
                isImportTargeted = targeted
            }
            .overlay {
                if isImportTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.daisyAccent, lineWidth: 2)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $pendingImport) { batch in
                AudioImportSheet(batch: batch)
            }
            .toolbar {
                // Shown whenever ANY session anywhere carries a tag, or a
                // tag filter is active — never yanked away mid-filter.
                if store.sessions.contains(where: { !$0.tag.isEmpty }) || model.tagFilter != nil {
                    ToolbarItem(placement: .primaryAction) {
                        tagSelector
                    }
                }
            }
            .task {
                await store.refresh()
                await store.monitorExternalChanges()
            }
            .onAppear {
                consumePendingSelection()
                consumePendingImport()
                if model.selectedIDs.isEmpty, let first = store.sessions.first?.id {
                    model.selectedIDs = [first]
                }
            }
            // Deep-link arrival: HomeView (and similar) can request a
            // specific session via `AppNavigation.openInLibrary(_:)`.
            // We react both on first appear (above) and any subsequent
            // arrivals while the column is already mounted.
            .onChange(of: AppNavigation.shared.pendingImportURLs?.count) { _, _ in
                consumePendingImport()
            }
            .onChange(of: AppNavigation.shared.pendingLibrarySelection) { _, _ in
                consumePendingSelection()
            }
            // Backspace / forward-Delete trigger the bulk-delete
            // confirmation. `.onDeleteCommand` only fires when the
            // responder chain has a focused view that opted in — our
            // rows use a manual gesture model, so the List never
            // receives focus and `.onDeleteCommand` never fires. Hidden
            // buttons with `.keyboardShortcut` work without focus.
            //
            // `.disabled(...)` guards both buttons so neither hijacks
            // Backspace while the user is typing in the search field
            // (TextField captures the key first anyway, but this is
            // belt-and-braces).
            .background {
                Group {
                    Button("Delete selected sessions") {
                        requestBulkDelete()
                    }
                    .keyboardShortcut(.delete, modifiers: [])

                    Button("Forward-delete selected sessions") {
                        requestBulkDelete()
                    }
                    .keyboardShortcut(.deleteForward, modifiers: [])

                    // ⌘+Delete — macOS convention (Finder, Notes, Mail
                    // all bind "move to trash" to ⌘+⌫). Mirrors the bare
                    // Backspace path; same alert, same destruction.
                    Button("Delete selected (⌘⌫)") {
                        requestBulkDelete()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
                .hidden()
                .disabled(selectedSessions.isEmpty)
            }
            .alert(
                deleteAlertTitle,
                isPresented: Binding(
                    get: { !model.pendingDelete.isEmpty },
                    set: { if !$0 { model.pendingDelete = [] } }
                )
            ) {
                Button("Cancel", role: .cancel) { model.pendingDelete = [] }
                Button("Delete", role: .destructive) {
                    let victims = model.pendingDelete
                    Task {
                        if victims.count == 1, let only = victims.first {
                            await store.delete(only)
                        } else {
                            await store.deleteMany(victims)
                        }
                        model.selectedIDs.subtract(victims.map(\.id))
                        model.pendingDelete = []
                    }
                }
                // Enter confirms — by default macOS binds Return to the
                // .cancel role and leaves destructive buttons un-defaulted
                // (anti-fat-finger). User explicitly asked for keyboard-
                // first delete flow, so we promote Delete to .defaultAction.
                // Esc still maps to Cancel via the .cancel role.
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(deleteAlertMessage)
            }
    }

    /// Pull the pending session id from `AppNavigation`, focus the
    /// row, and clear the request so it doesn't fire again. Called
    /// on appear AND on changes — the latter handles deep-links
    /// while the Library tab is already the active one.
    /// Files that arrived via Finder "Open With" / the Dock icon
    /// (`AppNavigation.importFiles`) → the same dialog as a drop.
    private func consumePendingImport() {
        guard let urls = AppNavigation.shared.pendingImportURLs else { return }
        AppNavigation.shared.pendingImportURLs = nil
        // The drop path refuses under the Notes chip; a file opened
        // from Finder must not vanish because of a filter.
        if model.scope == .notes { model.scope = .all }
        _ = importDroppedFiles(urls)
    }

    private func consumePendingSelection() {
        guard let pending = AppNavigation.shared.pendingLibrarySelection else { return }
        if store.sessions.contains(where: { $0.id == pending }) {
            model.selectedIDs = [pending]
        }
        AppNavigation.shared.pendingLibrarySelection = nil
    }

    /// Resolve the current selection into a delete-confirmation
    /// request. No-op if nothing's selected. Shared by the Backspace
    /// shortcut and (potentially) any future bulk-delete button.
    private func requestBulkDelete() {
        let toDelete = selectedSessions
        guard !toDelete.isEmpty else { return }
        model.pendingDelete = toDelete
    }

    private var deleteAlertTitle: String {
        let n = model.pendingDelete.count
        if n <= 1 { return String(localized: "Delete this recording?") }
        return String(localized: "Delete \(n) recordings?")
    }

    private var deleteAlertMessage: String {
        let n = model.pendingDelete.count
        if n <= 1 {
            return String(localized: "Audio, transcript, summary and screenshots will be removed from disk. This can't be undone.")
        }
        return String(localized: "Audio, transcript, summary and screenshots for all \(n) sessions will be removed from disk. This can't be undone.")
    }

    // MARK: - Row context menu

    /// Same actions as SessionDetailView's ellipsis menu — Move /
    /// Send to Notion / Send to Claude / Reveal / Delete. Skips
    /// "Re-summarize" because that's a heavy async op better
    /// triggered from the detail view's banner-feedback flow.
    ///
    /// If the user right-clicked a row that's part of a multi-
    /// selection, Delete applies to the whole selection (matches
    /// Finder behaviour). Otherwise it acts on just this row.
    @ViewBuilder
    private func sessionContextMenu(for session: StoredSession) -> some View {
        Menu {
            ForEach(moveTargets, id: \.folder.slug) { row in
                let f = row.folder
                Button {
                    let targets = sessionsForRowAction(session)
                    move(targets, to: f)
                } label: {
                    let label = row.isChild ? "    \(f.name)" : f.name
                    if sessionsForRowAction(session).allSatisfy({ $0.folderSlug == f.slug }) {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label("Move to folder…", systemImage: "folder")
        }
        Divider()
        Button {
            copyTranscript(of: session)
        } label: {
            Label("Copy transcript", systemImage: "doc.on.doc")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            // Visible selection only — a right-click must never sweep up
            // rows the current filter is hiding.
            let multi = model.visibleSelection(in: store.sessions)
            if multi.count > 1, multi.contains(where: { $0.id == session.id }) {
                model.pendingDelete = multi
            } else {
                model.pendingDelete = [session]
            }
        } label: {
            let multi = model.visibleSelectionCount
            if multi > 1 && model.selectedIDs.contains(session.id) {
                Label(String(localized: "Delete \(multi) selected"), systemImage: "trash")
            } else {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Copy the on-disk transcript.md to the clipboard. Lightweight
    /// version of the detail-view copy action — same two-flavor write
    /// (MarkdownClipboard.swift): semantic HTML for rich paste targets
    /// (Slack / Notion / Gmail / Apple Notes), raw markdown for plain
    /// ones (Obsidian / Claude / editors). The leading YAML frontmatter
    /// is stripped — it belongs only in the .md file on disk and the
    /// detail view's explicit "Copy for Obsidian", never in a copy the
    /// user drops into a chat or note (was: raw file, frontmatter and
    /// all, written as plain text only — literal `##`/`**` everywhere
    /// but Obsidian).
    private func copyTranscript(of session: StoredSession) {
        guard let url = session.transcriptURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        RichClipboard.copy(markdown: Self.strippingFrontmatter(raw))
    }

    /// Drop a leading `---`-fenced YAML block, returning just the body.
    /// Inverse of `SessionDetailView.onDiskFrontmatter`; returns the
    /// input unchanged when there is no well-formed frontmatter.
    private static func strippingFrontmatter(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return raw }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(i + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            // Search header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $model.query)
                    .textFieldStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            // Bumped from 8 → 14 in 1.0.6 because the folder chip row
            // visually touched the search bar — the capsule of the
            // "All" chip sat right under the text-field's baseline.
            .padding(.bottom, 14)

            // One row: All · Recordings · Notes · projects. Notes used
            // to be a separate sidebar tab; they share folders, tags,
            // model and files with recordings, so kind is a chip here
            // now (2026-09-07), sitting in the same row as the projects
            // rather than in a second row of its own (Egor 2026-09-10).
            filterChips
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if let importRunnerLine {
                HStack(spacing: 8) {
                    if importRunner.isRunning || ImportTranscriptionQueue.shared.activeJobID != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(importRunnerLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            // Manual selection model keeps the custom neutral highlight
            // while preserving Finder-style Shift / Cmd-click behaviour:
            //   • bare click  → select only this row
            //   • Cmd-click   → toggle this row in the selection
            //   • Shift-click → extend selection from anchor to this row
            // (matches Finder / Mail conventions). Anchor is the last
            // row that was selected by a bare click.
            List {
                ForEach(filteredSessions) { session in
                    SessionRow(session: session)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        // Selection = the sidebar menu's borderless fill;
                        // hover = the subtle Home-style highlight.
                        .modifier(LibraryRowHighlight(isSelected: model.selectedIDs.contains(session.id)))
                        .contentShape(Rectangle())
                        .gesture(rowTapGesture(for: session))
                        .contextMenu {
                            sessionContextMenu(for: session)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.pendingDelete = [session]
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .foregroundStyle(.white)
                            }
                            .tint(Color.daisyDestructiveControl)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if scopedSessions.isEmpty && !store.isLoading {
                    if scope == .notes {
                        ContentUnavailableView(
                            "No notes yet",
                            systemImage: "note.text",
                            description: Text("Hold your dictation key, or use the voice-note shortcut, to capture a quick note. It'll land here.")
                        )
                    } else if scope == .recordings {
                        ContentUnavailableView(
                            "No recordings yet",
                            systemImage: "tray",
                            description: Text("When you stop a recording, it'll appear here.")
                        )
                    } else {
                        ContentUnavailableView(
                            "Nothing here yet",
                            systemImage: "tray",
                            description: Text("Recordings and notes will appear here as you make them.")
                        )
                    }
                } else if filteredSessions.isEmpty && !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if filteredSessions.isEmpty, model.tagFilter == nil, let f = model.folderFilter {
                    // Kind-neutral: a project holds recordings and notes
                    // alike now that kind is a chip in the same row.
                    // Only claim the project is empty when no tag is
                    // narrowing it — otherwise the tag is what emptied
                    // the pane, and "move something in" is bad advice.
                    ContentUnavailableView(
                        "Nothing in \(f.name)",
                        systemImage: "folder",
                        description: Text("Move a recording or a note into this project from its detail view.")
                    )
                } else if filteredSessions.isEmpty, let tag = model.tagFilter {
                    // A tag that matches nothing under the current chip
                    // used to leave a blank pane with no explanation.
                    ContentUnavailableView(
                        tag.isEmpty
                            ? String(localized: "Nothing untagged here")
                            : String(localized: "Nothing tagged “\(tag)” here"),
                        systemImage: "tag",
                        description: Text("Pick another tag, or choose All tags to clear the filter.")
                    )
                }
            }

            // Counted over the visible selection, so the bar never
            // offers to act on rows a filter is hiding.
            if selectedSessions.count > 1 {
                bulkSelectionBar
            }
        }
    }

    private var bulkSelectionBar: some View {
        HStack(spacing: 10) {
            Button {
                toggleSelectAll()
            } label: {
                Label(
                    allVisibleSelected ? String(localized: "Deselect all") : String(localized: "Select all"),
                    systemImage: allVisibleSelected ? "checkmark.circle.fill" : "circle"
                )
                .labelStyle(.iconOnly)
            }
            .help(allVisibleSelected ? String(localized: "Deselect all") : String(localized: "Select all"))

            Text(String(localized: "\(selectedSessions.count) selected"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 4)

            Menu {
                ForEach(moveTargets, id: \.folder.slug) { row in
                    let folder = row.folder
                    Button {
                        move(selectedSessions, to: folder)
                    } label: {
                        let label = row.isChild ? "    \(folder.name)" : folder.name
                        Text(label)
                    }
                }
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(selectedSessions.isEmpty)

            Button(role: .destructive) {
                requestBulkDelete()
            } label: {
                Label("Delete", systemImage: "trash")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyDestructiveControl)
            .disabled(selectedSessions.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.daisyBgElevated)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(height: 0.5)
        }
    }

    /// The selection, narrowed to what's actually on screen.
    ///
    /// Every bulk action reads this, and that narrowing is the whole
    /// point: `selectedIDs` survives a filter change, so selecting four
    /// rows under All and then picking a tag only one of them carries
    /// used to leave Delete acting on three sessions the user could no
    /// longer see. Filters are not a weaker promise than the list —
    /// what you can't see, you can't destroy.
    private var selectedSessions: [StoredSession] {
        filteredSessions.filter { model.selectedIDs.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !filteredSessions.isEmpty
            && filteredSessions.allSatisfy { model.selectedIDs.contains($0.id) }
    }

    private func toggleSelectAll() {
        let visibleIDs = Set(filteredSessions.map(\.id))
        if allVisibleSelected {
            model.selectedIDs.subtract(visibleIDs)
        } else {
            model.selectedIDs.formUnion(visibleIDs)
        }
    }

    private func sessionsForRowAction(_ session: StoredSession) -> [StoredSession] {
        let selected = selectedSessions
        if selected.count > 1, model.selectedIDs.contains(session.id) {
            return selected
        }
        return [session]
    }

    private func move(_ sessions: [StoredSession], to folder: SessionFolder) {
        guard !sessions.isEmpty else { return }
        Task {
            await store.moveMany(sessions, to: folder)
            model.selectedIDs.subtract(sessions.map(\.id))
            let message = sessions.count == 1
                ? String(localized: "Moved to \(folder.name)")
                : String(localized: "Moved \(sessions.count) items to \(folder.name)")
            ToastCenter.shared.show(message, style: .success)
        }
    }

    /// SwiftUI gesture that runs the multi-select / single-select
    /// logic. Read the current event's modifier flags from NSEvent
    /// (SwiftUI's `.onTapGesture` doesn't carry modifiers).
    private func rowTapGesture(for session: StoredSession) -> some Gesture {
        TapGesture().onEnded {
            let mods = NSEvent.modifierFlags
            if mods.contains(.shift), let anchor = model.selectedIDs.first ?? store.sessions.first?.id {
                // Range select between anchor and this row.
                let ids = filteredSessions.map(\.id)
                if let a = ids.firstIndex(of: anchor),
                   let b = ids.firstIndex(of: session.id) {
                    let range = a <= b ? a...b : b...a
                    model.selectedIDs = Set(ids[range])
                    return
                }
                model.selectedIDs = [session.id]
            } else if mods.contains(.command) {
                // Toggle this row in the selection.
                if model.selectedIDs.contains(session.id) {
                    model.selectedIDs.remove(session.id)
                } else {
                    model.selectedIDs.insert(session.id)
                }
            } else {
                // Bare click — single select.
                model.selectedIDs = [session.id]
            }
        }
    }

    /// Corpus narrowed to the selected KIND chip, BEFORE the user's own
    /// project/tag/search filters. The list and `visibleBeforeTagFilter`
    /// read from this. The chip counts and the tag menu deliberately do
    /// NOT: a chip that showed its own count would read zero the moment
    /// you stood on a filter that empties it, and a tag would vanish
    /// from the menu you were using — both bugs we already shipped once.
    private var scopedSessions: [StoredSession] {
        // Split by KIND, not by folder: recordings and notes share the
        // same projects, so each kind chip spans ALL projects. (Was
        // `folderSlug` vs the Notes folder — the coupling this whole
        // change removed.)
        switch scope {
        case .all:        return store.sessions
        case .recordings: return store.sessions.filter { $0.kind == .recording }
        case .notes:      return store.sessions.filter { $0.kind == .note }
        }
    }

    private var filteredSessions: [StoredSession] {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = scopedSessions
        if let f = model.folderFilter {
            // Selecting a project parent aggregates its child folders'
            // records too; a leaf folder scopes to just itself.
            let scope = folders.slugScope(for: f)
            pool = pool.filter { scope.contains($0.folderSlug) }
        }
        if let t = model.tagFilter {
            pool = pool.filter { $0.tag == t }
        }
        if !trimmed.isEmpty {
            // Index-prefiltered substring search — same results as
            // filtering on `matches(query:)` directly, but without
            // re-scanning every transcript on each keystroke.
            pool = store.sessionsMatching(trimmed, in: pool)
        }
        return pool
    }

    /// Every tag in the corpus, carrying its count under the CURRENT
    /// chip — so an entry can legitimately read zero rather than
    /// disappear. Sorted by count desc then alphabetically; "Untagged"
    /// (empty tag) is appended last so it's visually demoted but still
    /// reachable. Powers the toolbar selector.
    var tagGroups: [(name: String, count: Int)] {
        // Which tags EXIST comes from the whole corpus; how many rows
        // each one has right now comes from the current chip. Counting
        // both from the current chip made the toolbar pill vanish the
        // moment you switched to a kind or project with no tags — taking
        // an active tag filter out of sight while it kept filtering
        // (Egor 2026-09-10). A tag that has nothing under this chip
        // stays listed with a zero.
        var counts: [String: Int] = [:]
        for s in store.sessions {
            counts[s.tag, default: 0] = 0
        }
        for s in visibleBeforeTagFilter {
            counts[s.tag, default: 0] += 1
        }
        let tagged = counts
            .filter { !$0.key.isEmpty }
            .map { (name: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.lowercased() < $1.name.lowercased()
            }
        let untaggedCount = counts[""] ?? 0
        // Same rule as the named tags: listed when the corpus has any
        // untagged session at all, or while it IS the active filter —
        // otherwise the pill would read "Untagged" with nothing checked
        // in the menu behind it.
        let untaggedExists = store.sessions.contains { $0.tag.isEmpty }
        if untaggedCount > 0 || untaggedExists || model.tagFilter == "" {
            return tagged + [(name: "", count: untaggedCount)]
        }
        return tagged
    }

    /// Rows the current kind/project chip shows before the tag filter
    /// narrows them — the denominator for tag counts.
    private var visibleBeforeTagFilter: [StoredSession] {
        guard let f = model.folderFilter else { return scopedSessions }
        let scope = folders.slugScope(for: f)
        return scopedSessions.filter { scope.contains($0.folderSlug) }
    }

    /// Single-selection dropdown listing every tag in use, with
    /// "All tags" reset at the top and "Untagged" demoted to the
    /// bottom. Pinned to the list column's toolbar trailing edge. An
    /// active filter gains primary ink without borrowing the
    /// recording/brand signal colour.
    private var tagSelector: some View {
        Menu {
            Button {
                model.tagFilter = nil
            } label: {
                if model.tagFilter == nil {
                    Label("All tags", systemImage: "checkmark")
                } else {
                    Text("All tags")
                }
            }
            Divider()
            ForEach(tagGroups, id: \.name) { group in
                let displayName = group.name.isEmpty ? String(localized: "Untagged") : group.name
                Button {
                    model.tagFilter = (model.tagFilter == group.name) ? nil : group.name
                } label: {
                    if model.tagFilter == group.name {
                        Label("\(displayName) · \(group.count)", systemImage: "checkmark")
                    } else {
                        Text("\(displayName) · \(group.count)")
                    }
                }
            }
        } label: {
            // DEFAULT style + toolbar = the system Liquid Glass pill (same
            // as Daisy / Add tag). NO capsule and NO .plain/.borderless —
            // those suppress the pill. `.menuIndicator(.hidden)` = no chevron.
            HStack(spacing: 4) {
                Image(systemName: "tag")
                Text(tagSelectorLabel)
            }
            .foregroundStyle(Color.daisyTextPrimary)
            .padding(.horizontal, 8)
        }
        .menuIndicator(.hidden)
        .tint(Color.daisyTextPrimary)
        .help("Filter by tag")
    }

    private var tagSelectorLabel: String {
        switch model.tagFilter {
        case nil:        return String(localized: "Tags")
        case .some(""):  return String(localized: "Untagged")
        case .some(let t): return t
        }
    }

    /// Move-to targets in hierarchy order: every folder (incl. Notes and
    /// Inbox), children indented under their parent project.
    private var moveTargets: [(folder: SessionFolder, isChild: Bool)] {
        var rows: [(folder: SessionFolder, isChild: Bool)] = []
        for root in folders.rootFolders {
            rows.append((root, false))
            for child in folders.children(of: root.slug) {
                rows.append((child, true))
            }
        }
        return rows
    }

    /// Folders flattened for the chip row in hierarchy order: each root
    /// followed by its children, after the kind chips in the same row.
    /// The system Notes
    /// folder is dropped from the chip row (it's still a valid move
    /// target): it's a legacy home for pre-split notes, redundant now
    /// that notes are identified by kind and default to Inbox — "All"
    /// still surfaces anything left in it.
    private var chipRows: [(folder: SessionFolder, isChild: Bool)] {
        var rows: [(folder: SessionFolder, isChild: Bool)] = []
        for root in folders.rootFolders where root.slug != SessionFolder.notes.slug {
            rows.append((root, false))
            for child in folders.children(of: root.slug) {
                rows.append((child, true))
            }
        }
        return rows
    }

    /// ONE chip row: All · Recordings · Notes · then the projects
    /// (Egor 2026-09-10 — two rows both starting with "All" read as a
    /// muddle). Kind and project are one exclusive choice here, not two
    /// independent filters: picking a kind clears the project and vice
    /// versa, which is what a row of chips looks like it does. Kind
    /// chips hide themselves when that kind is empty, so a person who
    /// never dictates never sees "Notes".
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FolderChip(
                    label: String(localized: "All"),
                    count: store.sessions.count,
                    isActive: model.scope == .all && model.folderFilter == nil
                ) {
                    selectKind(.all)
                }
                ForEach(kindChipCases, id: \.self) { kind in
                    FolderChip(
                        label: kind.title,
                        count: kindCount(kind),
                        isActive: model.scope == kind && model.folderFilter == nil
                    ) {
                        selectKind(kind)
                    }
                }
                // Project hierarchy, flattened for the horizontal chip
                // row: each root, immediately followed by its child
                // folders (prefixed "↳"). A parent's count aggregates its
                // children (matches what selecting it shows); a leaf
                // counts only itself. Notes is a kind chip above, not a
                // project, so its folder is dropped from this list.
                ForEach(chipRows, id: \.folder.slug) { row in
                    let f = row.folder
                    let scope = row.isChild ? [f.slug] : folders.slugScope(for: f)
                    let count = store.sessions.filter { scope.contains($0.folderSlug) }.count
                    FolderChip(
                        label: row.isChild ? "↳ \(f.name)" : f.name,
                        count: count,
                        isActive: model.folderFilter?.slug == f.slug
                    ) {
                        if model.folderFilter?.slug == f.slug {
                            selectKind(.all)
                        } else {
                            model.scope = .all
                            model.folderFilter = f
                            pruneSelectionToVisibleRows()
                        }
                    }
                }
            }
        }
    }

    /// Kind chips worth showing: a kind with nothing in it is noise —
    /// unless it's the active filter, because hiding the chip a person
    /// is currently standing on would strand them on an empty list with
    /// no way back.
    private var kindChipCases: [LibraryScope] {
        [.recordings, .notes].filter { kindCount($0) > 0 || model.scope == $0 }
    }

    /// Counts are of the whole corpus (before project/tag/search
    /// narrowing) so the person sees what each kind holds, not what the
    /// current project happens to contain.
    private func kindCount(_ kind: LibraryScope) -> Int {
        switch kind {
        case .all:        store.sessions.count
        case .recordings: store.sessions.filter { $0.kind == .recording }.count
        case .notes:      store.sessions.filter { $0.kind == .note }.count
        }
    }

    private func selectKind(_ kind: LibraryScope) {
        model.scope = kind
        model.folderFilter = nil
        pruneSelectionToVisibleRows()
    }

    /// A selection made under another filter would leave the detail pane
    /// showing a row the list no longer has.
    private func pruneSelectionToVisibleRows() {
        // Against the kind AND project narrowing, not just the kind:
        // otherwise picking a project leaves a selection from another
        // one alive, and the detail pane shows a row the list doesn't
        // have.
        let visible = visibleBeforeTagFilter
        model.selectedIDs = model.selectedIDs.filter { id in
            visible.contains { $0.id == id }
        }
    }

}

// MARK: - Detail column (detail column of the split)

/// The session detail pane: one selected session → `SessionDetailView`
/// (whose own `.toolbar` supplies the Add-tag / Summarize / ⋯ items in
/// the detail region), several selected → a bulk-delete empty state,
/// none → a "pick a recording" placeholder. Reads the shared `model`.
struct LibraryDetailColumn: View {
    @Bindable var model: LibraryModel
    @Bindable var store = SessionStore.shared

    var body: some View {
        if let session = model.singleSelected {
            SessionDetailView(initialSession: session)
        } else if model.visibleSelectionCount > 1 {
            multiSelectDetail
        } else {
            emptyDetail
        }
    }

    private var multiSelectDetail: some View {
        ContentUnavailableView {
            Label(selectionTitle, systemImage: "checkmark.circle")
        } description: {
            Text("Move or delete the selection using the actions below the list.")
        } actions: {
            Button(role: .destructive) {
                model.pendingDelete = model.visibleSelection(in: store.sessions)
            } label: {
                Label(String(localized: "Delete \(model.visibleSelectionCount) sessions…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyDestructiveControl)
            .foregroundStyle(.white)
        }
    }

    private var selectionTitle: String {
        String(localized: "\(model.visibleSelectionCount) selected")
    }

    private var emptyDetail: some View {
        ContentUnavailableView(
            "Select a recording",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Pick a recording on the left to read its transcript and summary.")
        )
    }
}

// MARK: - Composite (Preview / non-split fallback)

/// Thin composite that stacks the two columns in a plain HStack. Used by
/// #Preview and available as a non-split fallback; MainView renders the
/// live Library/Notes tabs as a genuine three-column NavigationSplitView
/// (see MainView.threeColumnSplit) rather than through this type.
struct LibraryView: View {
    /// Source-compatibility alias — callers still write `LibraryView.Scope`.
    typealias Scope = LibraryScope

    @State private var model: LibraryModel

    init(scope: Scope = .all) {
        _model = State(initialValue: LibraryModel(scope: scope))
    }

    var body: some View {
        HStack(spacing: 0) {
            LibraryListColumn(model: model)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            LibraryDetailColumn(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Sidebar row

private struct SessionRow: View {
    let session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                badges
            }
            HStack(spacing: 6) {
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let contentLabel {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(contentLabel)
                        .font(.caption)
                        .foregroundStyle(
                            session.contentState == .transcript ? Color.secondary : Color.orange
                        )
                }
                if session.hasSummary {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    // Word, not the sparkle glyph — same reasoning as
                    // the Home recents row: ✦ read as decoration.
                    Text("Summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Has AI summary")
                }
                if !session.tag.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(session.tag)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.daisyTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.daisySelectionBackground, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.daisySelectionBorder, lineWidth: 0.5)
                        )
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            switch session.contentState {
            case .audioOnly:
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Audio without transcript")
            case .empty:
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Empty folder")
            case .inCloud:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Stored in iCloud — download in Finder to open")
            case .transcript:
                EmptyView()
            }
            // `speaker.wave.2` (hasSystemAudio) removed in 1.0.6.4 —
            // it was repeating what the session title already says
            // ("Meeting …" implies system audio was on). Removed
            // here for parity with SessionDetailView header where it
            // was dropped for the same reason.
            if session.hasScreenshots {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "\(session.screenshotURLs.count) screenshots"))
            }
        }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: session.startedAt)
    }

    private var formattedDuration: String {
        let total = max(0, session.durationSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// nil hides the subtitle chunk entirely (empty folders: the quiet
    /// corner icon is enough — an orange "Empty folder" label next to
    /// every Finder-created folder read as an error state).
    private var contentLabel: String? {
        switch session.contentState {
        case .transcript: formattedDuration
        case .audioOnly:
            ImportTranscriptionQueue.shared.rowLabel(forSession: session.id)
                ?? String(localized: "Audio without transcript")
        case .empty: nil
        case .inCloud: String(localized: "Stored in iCloud")
        }
    }
}

// MARK: - Folder chip

private struct FolderChip: View {
    let label: String
    let count: Int
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isActive ? Color.daisyTextSecondary : Color.daisyTextTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive ? Color.daisySelectionBackground : Color.daisyBgElevated)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Color.daisySelectionBorder : Color.daisyDivider,
                        lineWidth: isActive ? 1 : 0.5
                    )
            )
            // Inert chips gave no sign they were clickable until you
            // clicked one (Egor 2026-09-10). Skipped on the active chip,
            // which already carries the selection fill.
            .daisyHover(Capsule(), isEnabled: !isActive)
            .foregroundStyle(Color.daisyTextPrimary)
        }
        .buttonStyle(.plain)
    }
}

/// Row selection + hover highlight for the Library list. Selection reuses
/// the sidebar menu's borderless fill (`daisySidebarSelection`); hovering an
/// unselected row shows the same subtle grey as the Home rows. No border —
/// that's what made the old selection read as a box rather than a menu pick.
private struct LibraryRowHighlight: ViewModifier {
    let isSelected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
    private var fill: Color {
        if isSelected { return Color.daisySidebarSelection }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

#Preview {
    LibraryView()
}
