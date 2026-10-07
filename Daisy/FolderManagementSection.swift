//
//  FolderManagementSection.swift
//  Daisy
//
//  Settings UI for managing Library folders (Settings → General →
//  "Folders"). The data model already supports custom folders —
//  `FolderStore` persists them and they flow into the Library sidebar,
//  the "Move to folder…" menu, MCP, and integration filters with no
//  extra wiring. This view is the create / rename / delete surface, plus
//  the "default folder for meetings" picker.
//
//  Embedding contract: renders ITS OWN `Section { … } header/footer` so
//  it can be dropped straight into a Settings `Form` (mirrors
//  the other sections). Don't wrap it in another Section.
//
//  Rows: system folders (Inbox / Notes) are plain, control-free — they're
//  structural and can't be renamed/deleted. Everything else (the seeded
//  defaults Private / Work / Calls + user folders) gets a pencil (rename
//  via a popup sheet) and a trash. Names are edited in a small sheet
//  rather than inline, because a `TextField` inside a grouped `Form`
//  renders as a label-left / field-right row, which looked broken.
//
//  Data-safety rules (folders are just a `daisy_folder:` slug in each
//  transcript's frontmatter):
//   • Delete a folder → its recordings move to Inbox FIRST (rewriting
//     their tag), THEN the folder is removed — otherwise
//     `FolderStore.folder(slug:)` would auto-recreate it from the still-
//     tagged sessions.
//   • The folder chosen as "default for meetings" can't be deleted (the
//     trash is disabled) so routing never points at a missing folder.
//   • Rename that changes the slug → add new, move sessions, remove old.
//     Casing-only rename → `renameInPlace`, no migration.
//

import DaisyCore
import SwiftUI

struct FolderManagementSection: View {
    @Bindable var settings: AppSettings
    @Bindable private var folders = FolderStore.shared
    @Bindable private var store = SessionStore.shared

    /// Non-nil drives the delete confirmation for a NON-empty folder
    /// (empty folders delete immediately — no dialog).
    @State private var pendingDelete: SessionFolder?
    /// Drives the add / rename name-editor sheet.
    @State private var editing: FolderEdit?
    /// Backlog 24 М-8: the folder whose trackers are being edited.
    @State private var editingTrackers: SessionFolder?

    var body: some View {
        Section {
            // Where calendar-bound / auto-started meetings file when the
            // session is still in Inbox. Manual recordings start in Inbox;
            // voice notes file into Notes. Resolved defensively to Inbox
            // if the chosen folder is later deleted.
            Picker("Default project for meetings", selection: $settings.defaultMeetingFolderSlug) {
                ForEach(folders.allFolders) { f in
                    Text(f.name).tag(f.slug)
                }
            }
            // Voice notes, screenshot notes and side notes from a meeting.
            Picker("Default project for notes", selection: $settings.defaultNoteFolderSlug) {
                ForEach(folders.allFolders) { f in
                    Text(f.name).tag(f.slug)
                }
            }

            // System (Inbox / Notes) — plain, no controls.
            ForEach(SessionFolder.system) { folder in
                systemRow(folder)
            }

            // Editable — seeded defaults (Private / Work / Calls) + user
            // folders. Rendered in hierarchy order: each root project,
            // then its child folders indented below. Rename via pencil
            // popup; re-parent via the folder menu; delete via trash.
            ForEach(customRows, id: \.folder.slug) { row in
                editableRow(row.folder, isChild: row.isChild)
            }

            addRow
        } header: {
            Text("Projects")
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { folder in
            Button("Move recordings to Inbox & delete", role: .destructive) {
                Task { await deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { folder in
            let n = countFor(folder)
            Text(String(localized: "\(n) recordings will move to Inbox. This can’t be undone."))
        }
        .sheet(item: $editingTrackers) { folder in
            FolderTrackersSheet(folder: folder)
        }
        .sheet(item: $editing) { edit in
            switch edit {
            case .add:
                FolderEditSheet(mode: .add) { addNamed($0) }
            case .rename(let folder):
                FolderEditSheet(mode: .rename(folder)) { attemptRename(folder, to: $0) }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func systemRow(_ folder: SessionFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(folder.name)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func editableRow(_ folder: SessionFolder, isChild: Bool) -> some View {
        let isDefault = isDefaultMeetingFolder(folder)
        HStack(spacing: 8) {
            // Child folders indent + use a corner glyph so the project
            // hierarchy reads at a glance.
            if isChild {
                Spacer().frame(width: 16)
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            } else {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(folder.name)
            Spacer(minLength: 8)

            // Re-parent menu. Hidden for a folder that already has
            // children (it's a top-level project — nesting it would make
            // a 3rd level, which the model forbids).
            if !folders.isParent(folder) {
                parentMenu(for: folder)
            }

            Button {
                editing = .rename(folder)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Rename")

            Button {
                editingTrackers = folder
            } label: {
                Image(systemName: FolderRegistryBridge.shared.project(for: folder.slug) == nil ? "link" : "link.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Project notes and trackers — what its summaries know, and where a step becomes an issue"))

            Button {
                requestDelete(folder)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(isDefault ? .tertiary : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isDefault)
            .help(isDefault ? String(localized: "Can’t delete a default project") : String(localized: "Delete project"))
        }
        .padding(.vertical, 2)
    }

    /// Menu to nest this folder under a parent project (or detach to
    /// root). Candidates are root-level custom projects other than this
    /// folder — the one-level rule means a parent can't itself be nested.
    @ViewBuilder
    private func parentMenu(for folder: SessionFolder) -> some View {
        Menu {
            Button {
                folders.setParent(folder, to: nil)
            } label: {
                if folder.parentSlug == nil {
                    Label("No parent (top level)", systemImage: "checkmark")
                } else {
                    Text("No parent (top level)")
                }
            }
            let candidates = eligibleParents(for: folder)
            if !candidates.isEmpty {
                Divider()
                ForEach(candidates) { parent in
                    Button {
                        folders.setParent(folder, to: parent.slug)
                    } label: {
                        if folder.parentSlug == parent.slug {
                            Label(parent.name, systemImage: "checkmark")
                        } else {
                            Text(parent.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Nest under a project")
    }

    private var addRow: some View {
        Button {
            editing = .add
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("New project")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    // MARK: - Queries

    /// Custom folders in hierarchy order: each root project followed by
    /// its child folders. `isChild` drives the row indent.
    private var customRows: [(folder: SessionFolder, isChild: Bool)] {
        var rows: [(folder: SessionFolder, isChild: Bool)] = []
        for root in folders.customFolders where root.parentSlug == nil {
            rows.append((root, false))
            for child in folders.children(of: root.slug) {
                rows.append((child, true))
            }
        }
        return rows
    }

    /// Root-level custom projects this folder could be nested under —
    /// everything except itself (a parent can't be nested, so all roots
    /// qualify as candidates).
    private func eligibleParents(for folder: SessionFolder) -> [SessionFolder] {
        folders.customFolders.filter { $0.parentSlug == nil && $0.slug != folder.slug }
    }

    private func countFor(_ folder: SessionFolder) -> Int {
        store.sessions.filter { $0.folderSlug == folder.slug }.count
    }

    /// The default for meetings OR notes — either one blocks deletion.
    private func isDefaultMeetingFolder(_ folder: SessionFolder) -> Bool {
        folder.slug == settings.defaultMeetingFolderSlug || folder.slug == settings.defaultNoteFolderSlug
    }

    // MARK: - Mutations

    /// Returns true when the folder was added; false (so the sheet stays
    /// open) on an empty name or a collision with an existing folder.
    private func addNamed(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if folders.allFolders.contains(where: { $0.slug == SessionFolder(name: trimmed).slug }) {
            ToastCenter.shared.show(String(localized: "A project named “\(trimmed)” already exists"), style: .warning)
            return false
        }
        folders.addFolder(named: trimmed)
        return true
    }

    /// Returns true when the rename was accepted. A casing-only rename
    /// applies synchronously; a slug-changing one is accepted here and its
    /// session migration runs in a Task. Returns false (sheet stays open)
    /// on an empty name or a collision with another folder.
    private func attemptRename(_ old: SessionFolder, to raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let new = SessionFolder(name: trimmed)

        // Casing-only rename — slug unchanged, no migration.
        if new.slug == old.slug {
            folders.renameInPlace(old, to: trimmed)
            return true
        }

        // Slug changes — must not collide with another existing folder.
        if folders.allFolders.contains(where: { $0.slug == new.slug }) {
            ToastCenter.shared.show(String(localized: "A project named “\(trimmed)” already exists"), style: .warning)
            return false
        }

        // Accepted. Add the target now so the UI shows it immediately and
        // the migration's re-parses find it; move every session over; then
        // drop the old folder (safe once nothing points at it).
        folders.addFolder(named: trimmed)
        // Keep the meeting-default setting pointed at the renamed folder.
        if settings.defaultMeetingFolderSlug == old.slug {
            settings.defaultMeetingFolderSlug = new.slug
        }
        if settings.defaultNoteFolderSlug == old.slug {
            settings.defaultNoteFolderSlug = new.slug
        }
        Task {
            for s in store.sessions where s.folderSlug == old.slug {
                await store.moveSession(s, to: new)
            }
            folders.removeFolder(old)
        }
        return true
    }

    private func requestDelete(_ folder: SessionFolder) {
        // The default meeting folder can't be deleted (trash is disabled
        // too — this is a defensive backstop).
        guard !isDefaultMeetingFolder(folder) else { return }
        if countFor(folder) > 0 {
            pendingDelete = folder
        } else {
            removeFolderAndSyncDefault(folder)
        }
    }

    private func deleteFolder(_ folder: SessionFolder) async {
        // Snapshot the matching sessions, move each to Inbox (rewrites the
        // transcript's folder tag), then remove the now-orphan-free folder.
        for s in store.sessions where s.folderSlug == folder.slug {
            await store.moveSession(s, to: .inbox)
        }
        removeFolderAndSyncDefault(folder)
    }

    /// Remove a folder and, if it was somehow the configured meeting
    /// default, reset that setting to Inbox so the Picker never points at
    /// a folder that no longer exists. (Deletion of the default is blocked
    /// in the UI, but stay defensive.)
    private func removeFolderAndSyncDefault(_ folder: SessionFolder) {
        folders.removeFolder(folder)
        if settings.defaultMeetingFolderSlug == folder.slug {
            settings.defaultMeetingFolderSlug = SessionFolder.inbox.slug
        }
        if settings.defaultNoteFolderSlug == folder.slug {
            settings.defaultNoteFolderSlug = SessionFolder.inbox.slug
        }
    }
}

// MARK: - Add / rename target

private enum FolderEdit: Identifiable {
    case add
    case rename(SessionFolder)

    var id: String {
        switch self {
        case .add: return "__add__"
        case .rename(let folder): return folder.slug
        }
    }
}

// MARK: - Name editor sheet

/// Small modal for creating or renaming a folder. `onSubmit` returns
/// whether the name was accepted — false (collision / empty) keeps the
/// sheet open so the user can fix it.
private struct FolderEditSheet: View {
    enum Mode {
        case add
        case rename(SessionFolder)
    }

    let mode: Mode
    let onSubmit: (String) -> Bool

    @State private var name: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(mode: Mode, onSubmit: @escaping (String) -> Bool) {
        self.mode = mode
        self.onSubmit = onSubmit
        switch mode {
        case .add:
            _name = State(initialValue: "")
        case .rename(let folder):
            _name = State(initialValue: folder.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText)
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private var titleText: String {
        switch mode {
        case .add: return String(localized: "New project")
        case .rename: return String(localized: "Rename project")
        }
    }

    private var saveLabel: String {
        switch mode {
        case .add: return String(localized: "Add")
        case .rename: return String(localized: "Rename")
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if onSubmit(trimmed) {
            dismiss()
        }
        // else: parent toasted a collision — keep the sheet open.
    }
}

// MARK: - Backlog 24 М-8: trackers

/// GitHub, Linear, Jira for one project — the same fields as on the phone,
/// in the folder registry both devices share.
private struct FolderTrackersSheet: View {
    let folder: SessionFolder
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var linearTeam = ""
    @State private var jiraBase = ""
    @State private var jiraProjectID = ""
    @State private var jiraIssueType = ""
    /// 03.10.2026: what every summary of this project is told.
    @State private var notes = ""
    @State private var usesMemory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project “\(folder.name)”").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes for summaries").font(.subheadline.weight(.medium))
                TextEditor(text: $notes)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 8))
                Text("Who is who, terms, what this work is about. Every summary of a meeting in this project reads it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Tell summaries about this project's earlier meetings", isOn: $usesMemory)
                Text("The summaries of the last few meetings here go to your summary provider with each new transcript, so a meeting is read as part of the project. Meetings with the same tag are added too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Trackers").font(.subheadline.weight(.medium))
            Form {
                TextField("GitHub repository", text: $repo, prompt: Text(verbatim: "owner/name"))
                TextField("Linear team", text: $linearTeam, prompt: Text(verbatim: "ENG"))
                TextField("Jira site", text: $jiraBase, prompt: Text(verbatim: "https://acme.atlassian.net"))
                TextField("Jira project ID", text: $jiraProjectID, prompt: Text(verbatim: "10001"))
                TextField("Jira issue type ID", text: $jiraIssueType, prompt: Text(String(localized: "optional")))
            }
            Text("A step from this project's meetings opens as a new issue there, filled in — you check it and create it. No sign-in; Daisy only builds the link.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    func clean(_ s: String) -> String? {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    FolderRegistryBridge.shared.setProject(
                        ProjectContext(repo: clean(repo), linearTeam: clean(linearTeam)?.uppercased(), jiraBase: clean(jiraBase),
                                       jiraProjectID: clean(jiraProjectID), jiraIssueType: clean(jiraIssueType),
                                       notes: clean(notes), memory: usesMemory ? nil : false),
                        for: folder.slug)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            let project = FolderRegistryBridge.shared.project(for: folder.slug)
            repo = project?.repo ?? ""
            linearTeam = project?.linearTeam ?? ""
            jiraBase = project?.jiraBase ?? ""
            jiraProjectID = project?.jiraProjectID ?? ""
            jiraIssueType = project?.jiraIssueType ?? ""
            notes = project?.notes ?? ""
            usesMemory = project?.usesMemory ?? true
        }
    }
}
