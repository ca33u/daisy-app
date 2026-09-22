//
//  SessionFolder.swift
//  Daisy
//
//  Project folder taxonomy for recordings. Used in two places:
//   • RecordingSession holds the active folder, which becomes the
//     `daisy_folder:` value in the transcript markdown frontmatter
//     when the session is saved.
//   • LibraryView filters the sidebar session list by selected folder.
//
//  The taxonomy is open — built-in defaults (Inbox / Private / Work
//  / Calls) plus user-defined folders persisted in UserDefaults.
//  Names are matched case-insensitively when reading back from the
//  filesystem so a transcript saved as "work" still appears under
//  "Work" in the UI.
//

import Foundation
import Observation

/// A folder is just a string identifier — `name` is the canonical
/// case-preserved label, `slug` is the lowercased token used for
/// frontmatter persistence and equality. Using a struct instead of an
/// enum lets users add custom folders without us shipping a code
/// change.
nonisolated struct SessionFolder: Identifiable, Hashable, Codable, Sendable {
    let name: String
    /// Slug of this folder's PARENT project, or nil for a root folder.
    /// One level only — a parent can't itself have a parent (enforced in
    /// FolderStore.setParent). System folders (Inbox / Notes) are always
    /// roots. Optional + synthesized `decodeIfPresent` means older stored
    /// folders (no key) decode as nil — free migration.
    var parentSlug: String? = nil
    var id: String { slug }
    var slug: String { name.lowercased() }

    /// Identity is the slug ALONE — not the parent or the name casing. A
    /// folder that gains/loses a parent is still the same folder, and
    /// `SessionFolder.system.contains(_:)` / `folderFilter?.slug == f.slug`
    /// comparisons must not be perturbed by the new field.
    static func == (lhs: SessionFolder, rhs: SessionFolder) -> Bool {
        lhs.slug == rhs.slug
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(slug)
    }
}

extension SessionFolder {
    nonisolated static let inbox   = SessionFolder(name: "Inbox")
    nonisolated static let notes   = SessionFolder(name: "Notes")
    nonisolated static let private_ = SessionFolder(name: "Private")
    nonisolated static let work    = SessionFolder(name: "Work")
    nonisolated static let calls   = SessionFolder(name: "Calls")

    /// System folders — ALWAYS present, never editable or removable.
    /// `inbox` is the fallback for unknown/cleared slugs AND the
    /// destination when a custom folder is deleted; it's also the default
    /// project for new notes and recordings alike.
    ///
    /// `notes` is RETAINED as a permanent folder but is no longer special
    /// for identity: notes vs recordings are now distinguished by
    /// `StoredSession.kind` / `daisy_kind:` (see SessionKind), not by
    /// living here. It's kept in `system` only so that the pre-split notes
    /// that DO carry `daisy_folder: notes` still resolve to a real,
    /// named, undeletable folder (labels, move targets, counts) — removing
    /// it would strand those slugs / auto-create a stray custom folder.
    /// New notes default to Inbox; this folder is a legacy home + an
    /// optional manual destination.
    nonisolated static let system: [SessionFolder] = [.inbox, .notes]

    /// Default buckets SEEDED once into the user's editable folder list
    /// (see `FolderStore.seedDefaultFoldersIfNeeded`). They're present
    /// out of the box so the Library has useful folders, but — unlike
    /// `system` — the user can rename or delete them like any custom
    /// folder (Egor 2026-06-20, was hardcoded built-in). `.work` is still
    /// a routing default in RecordingSession; that constant stays valid
    /// even if the user removes the folder.
    nonisolated static let seededDefaults: [SessionFolder] = [.private_, .work, .calls]

    /// Everything that exists on a fresh install (system + seeded).
    nonisolated static let builtIn: [SessionFolder] = system + seededDefaults
}

// MARK: - Store

@Observable
@MainActor
final class FolderStore {
    static let shared = FolderStore()

    /// All folders the user has — built-in + custom. Custom folders
    /// appear after built-in.
    var allFolders: [SessionFolder] {
        SessionFolder.system + customFolders
    }

    private(set) var customFolders: [SessionFolder] {
        didSet {
            persist()
        }
    }

    private static let storageKey = "daisy.customFolders"
    private static let didSeedKey = "daisy.didSeedDefaultFolders"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SessionFolder].self, from: data) {
            self.customFolders = decoded
        } else {
            self.customFolders = []
        }
        seedDefaultFoldersIfNeeded()
    }

    /// One-time migration (Egor 2026-06-20): Private / Work / Calls used
    /// to be hardcoded, non-editable built-ins. They're now editable, so
    /// seed them into `customFolders` once — at the front, in order — for
    /// both fresh installs and upgrades. A flag prevents re-seeding, so a
    /// user who later deletes one doesn't get it back. Any whose slug is
    /// already present is skipped (defensive — couldn't happen while they
    /// were built-in, since `addFolder` blocked those slugs).
    private func seedDefaultFoldersIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didSeedKey) else { return }
        let taken = Set(customFolders.map(\.slug)).union(SessionFolder.system.map(\.slug))
        let toSeed = SessionFolder.seededDefaults.filter { !taken.contains($0.slug) }
        if !toSeed.isEmpty {
            customFolders.insert(contentsOf: toSeed, at: 0)  // didSet persists
        }
        defaults.set(true, forKey: Self.didSeedKey)
    }

    /// Add a new custom folder. No-op if a folder with the same slug
    /// already exists (built-in or custom). Returns the canonical
    /// folder reference.
    @discardableResult
    func addFolder(named raw: String) -> SessionFolder {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .inbox }
        let candidate = SessionFolder(name: trimmed)
        if let existing = allFolders.first(where: { $0.slug == candidate.slug }) {
            return existing
        }
        customFolders.append(candidate)
        return candidate
    }

    /// Remove a folder. System folders (Inbox / Notes) can't be removed;
    /// seeded defaults (Private / Work / Calls) and user folders can.
    /// Any children are orphaned to root (parentSlug → nil) rather than
    /// deleted — their sessions and identity survive.
    func removeFolder(_ folder: SessionFolder) {
        guard !SessionFolder.system.contains(folder) else { return }
        for idx in customFolders.indices where customFolders[idx].parentSlug == folder.slug {
            customFolders[idx].parentSlug = nil
        }
        customFolders.removeAll { $0.slug == folder.slug }
    }

    // MARK: - Hierarchy (one level: project → child folders)

    /// Root-level folders (no parent) in display order: system folders
    /// first, then custom roots. Children are reached via `children(of:)`.
    var rootFolders: [SessionFolder] {
        SessionFolder.system + customFolders.filter { $0.parentSlug == nil }
    }

    /// Direct children of a parent project, in stored order.
    func children(of parentSlug: String) -> [SessionFolder] {
        customFolders.filter { $0.parentSlug == parentSlug.lowercased() }
    }

    /// True when this folder has at least one child — i.e. it's acting
    /// as a project parent.
    func isParent(_ folder: SessionFolder) -> Bool {
        customFolders.contains { $0.parentSlug == folder.slug }
    }

    /// The folder's own slug PLUS every child's slug. Used by the Library
    /// filter so selecting a project shows the records of all its folders.
    func slugScope(for folder: SessionFolder) -> Set<String> {
        var scope: Set<String> = [folder.slug]
        scope.formUnion(children(of: folder.slug).map(\.slug))
        return scope
    }

    /// Assign (or clear, with nil) a folder's parent project. Enforces
    /// the one-level rule and blocks system folders on both ends. No-op
    /// on any violation so the model can never reach an illegal shape:
    ///   • system folders (Inbox / Notes) are never children or parents;
    ///   • a folder that already has children can't become a child
    ///     (would create a 3rd level);
    ///   • the chosen parent can't itself be a child (same reason);
    ///   • no self-parenting.
    func setParent(_ folder: SessionFolder, to newParentSlug: String?) {
        guard !SessionFolder.system.contains(folder),
              let idx = customFolders.firstIndex(where: { $0.slug == folder.slug })
        else { return }

        guard let newParentSlug = newParentSlug?.lowercased() else {
            customFolders[idx].parentSlug = nil   // detach to root
            return
        }
        guard newParentSlug != folder.slug,
              !isParent(folder),                                   // folder has no children
              let parent = customFolders.first(where: { $0.slug == newParentSlug }),
              parent.parentSlug == nil                             // parent is itself a root
        else { return }
        customFolders[idx].parentSlug = newParentSlug
    }

    /// Resolve a stored slug to a LIVE folder without auto-creating one
    /// (unlike `folder(slug:)`). Returns nil when no such folder exists —
    /// e.g. the configured default-meeting folder was since deleted — so
    /// the caller can fall back to `.inbox`.
    func existingFolder(slug: String) -> SessionFolder? {
        allFolders.first { $0.slug == slug.lowercased() }
    }

    /// Rename a custom folder IN PLACE, ONLY when the new name lowercases
    /// to the SAME slug (e.g. casing/spacing tweaks like "side notes" →
    /// "Side Notes"). The `daisy_folder:` slug stored in every transcript
    /// is unchanged, so no session migration is needed and the folder
    /// keeps its position in the list. Slug-CHANGING renames must instead
    /// rewrite each transcript's folder tag, so the caller does them as
    /// add-new → moveSession(old→new) → removeFolder(old); see
    /// `FolderManagementSection`. System folders (Inbox / Notes) are
    /// immutable; seeded defaults and user folders are not.
    func renameInPlace(_ folder: SessionFolder, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !SessionFolder.system.contains(folder),
              SessionFolder(name: trimmed).slug == folder.slug,
              let idx = customFolders.firstIndex(where: { $0.slug == folder.slug }) else { return }
        customFolders[idx] = SessionFolder(name: trimmed)
    }

    /// Look up a folder by its frontmatter slug. Falls back to Inbox
    /// for unknown / missing slugs so old transcripts (pre-folders)
    /// still surface.
    func folder(slug: String?) -> SessionFolder {
        guard let slug, !slug.isEmpty else { return .inbox }
        if let match = allFolders.first(where: { $0.slug == slug.lowercased() }) {
            return match
        }
        // Unknown slug — keep the user's data by auto-creating a
        // matching folder. They typed it in once, we shouldn't lose
        // it.
        return addFolder(named: slug)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customFolders) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        // Ф3-C: mirror into the shared registry (no-op while applying
        // a change that came from it).
        FolderRegistryBridge.shared.localChanged()
    }
}
