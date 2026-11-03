//
//  FolderRegistryBridge.swift
//  Daisy
//
//  backlog 9 Ф3-C: `FolderStore` (UserDefaults, this Mac) ⇄
//  `FolderRegistry` (iCloud key-value store, every device). The store
//  stays the app's source of truth for the UI; the bridge mirrors each
//  local change into the registry and applies what other devices did.
//
//  Applying a remote deletion also moves this Mac's sessions out of the
//  folder into Inbox — what the deleting device did with its own; into
//  the project's new name when the deletion was a rename (a live entry
//  carries the same stable id) — so
//  the §9 rule ("an unknown slug recreates the project") does not bring
//  the folder straight back from a session the text sync has not
//  rewritten yet.
//
//  Backlog 41: each project's stable id rides along. This Mac's id goes
//  up where the registry has none; where it has one — given out earlier,
//  or by the device that renamed the project — this Mac takes it.
//

import DaisyCore
import Foundation
import os

@MainActor
final class FolderRegistryBridge {
    static let shared = FolderRegistryBridge()

    private let store = FolderRegistryStore()
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Folders")
    /// What the registry looked like when we last mirrored the local list.
    private var mirrored: [String: FolderRegistry.Entry] = [:]
    private var applying = false
    /// `start()` ran. Before it, `localChanged` may be called from inside
    /// `FolderStore`'s initializer, where `apply` (which reads
    /// `FolderStore.shared`) would be a recursive dispatch_once.
    private var started = false
    private var settling = false

    private init() {}

    // MARK: - Backlog 24 М-8: a folder's trackers

    func project(for slug: String) -> ProjectContext? {
        store.registry.entry(slug)?.project
    }

    func setProject(_ project: ProjectContext, for slug: String) {
        store.update { registry in registry.setProject(project, for: slug) }
    }

    func start() {
        started = true
        store.onExternalChange = { [weak self] registry in self?.apply(registry) }
        // First run: whatever this Mac has and the registry lacks goes up;
        // whatever the registry has and this Mac lacks comes down.
        apply(store.registry)
        localChanged(folders: FolderStore.shared.customFolders)
    }

    /// Called by `FolderStore` after every persist, with the list it just
    /// wrote. The list is handed over, never read back from
    /// `FolderStore.shared`: on a fresh install the first persist happens
    /// INSIDE `FolderStore`'s own initializer (the seeded Private / Work
    /// / Calls), and reading `shared` from there is a recursive
    /// dispatch_once — a crash on the very first launch (crash report
    /// 06.10.2026, 09:37, in the test host; every new user since 1.0.8.18
    /// would have hit it).
    func localChanged(folders: [SessionFolder]) {
        guard !applying else { return }
        let local = Dictionary(uniqueKeysWithValues: folders.map { ($0.slug, $0) })
        store.update { registry in
            for folder in folders {
                let current = registry.entries[folder.slug]
                if current == nil || current!.isDeleted || current!.name != folder.name || current!.parentSlug != folder.parentSlug
                    || current!.id == nil {
                    registry.upsert(name: folder.name, parentSlug: folder.parentSlug, id: folder.stableID)
                }
            }
            for (slug, entry) in registry.entries where !entry.isDeleted && local[slug] == nil && mirrored[slug] != nil {
                // It was here and is gone: a local deletion.
                registry.remove(slug)
            }
        }
        mirrored = store.registry.entries
        // The registry kept an id of its own for a folder this Mac named
        // differently (another device gave it out first): take it. Only
        // once started — `start()` itself applies first, then mirrors —
        // and on the next turn: this runs inside `FolderStore`'s `didSet`,
        // perhaps in the middle of a loop over its folders.
        guard started, !settling else { return }
        let differs = folders.contains { folder in
            guard let id = store.registry.entry(folder.slug)?.id else { return false }
            return id != folder.stableID
        }
        guard differs else { return }
        settling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.settling = false
            self.apply(self.store.registry)
        }
    }

    private func apply(_ registry: FolderRegistry) {
        applying = true
        defer { applying = false; mirrored = registry.entries }
        let folders = FolderStore.shared
        // Parents before children: `setParent` refuses a parent this Mac
        // doesn't have yet — the new name of a renamed project, say.
        let ordered = registry.entries.sorted { a, b in
            (a.value.parentSlug == nil ? 0 : 1, a.key) < (b.value.parentSlug == nil ? 0 : 1, b.key)
        }
        for (slug, entry) in ordered {
            let existing = folders.existingFolder(slug: slug)
            if entry.isDeleted {
                if let existing, !SessionFolder.system.contains(existing) {
                    let affected = SessionStore.shared.sessions.filter { $0.folderSlug.lowercased() == slug }
                    if !affected.isEmpty {
                        let destination = renamedFolder(from: entry, in: registry) ?? .inbox
                        Task { @MainActor in await SessionStore.shared.moveMany(affected, to: destination) }
                    }
                    folders.removeFolder(existing)
                    log.notice("Folder removed elsewhere: \(slug, privacy: .public)")
                }
                continue
            }
            if existing == nil {
                let added = folders.addFolder(named: entry.name, stableID: entry.id)
                if let parent = entry.parentSlug { folders.setParent(added, to: parent) }
                log.notice("Folder from another device: \(entry.name, privacy: .public)")
            } else if let existing {
                if existing.name != entry.name { folders.renameInPlace(existing, to: entry.name) }
                if existing.parentSlug != entry.parentSlug { folders.setParent(existing, to: entry.parentSlug) }
                if let id = entry.id { folders.setStableID(id, for: existing) }
            }
        }
    }

    /// The live folder a removed entry was renamed to elsewhere — the one
    /// carrying its stable id — added here if this Mac doesn't have it yet.
    private func renamedFolder(from removed: FolderRegistry.Entry, in registry: FolderRegistry) -> SessionFolder? {
        guard let id = removed.id, let slug = registry.slug(forID: id), let entry = registry.entry(slug) else { return nil }
        let folders = FolderStore.shared
        return folders.existingFolder(slug: slug) ?? folders.addFolder(named: entry.name, stableID: id)
    }
}
