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
//  folder into Inbox — what the deleting device did with its own — so
//  the §9 rule ("an unknown slug recreates the project") does not bring
//  the folder straight back from a session the text sync has not
//  rewritten yet.
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

    private init() {}

    // MARK: - Backlog 24 М-8: a folder's trackers

    func project(for slug: String) -> ProjectContext? {
        store.registry.entry(slug)?.project
    }

    func setProject(_ project: ProjectContext, for slug: String) {
        store.update { registry in registry.setProject(project, for: slug) }
    }

    func start() {
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
                if current == nil || current!.isDeleted || current!.name != folder.name || current!.parentSlug != folder.parentSlug {
                    registry.upsert(name: folder.name, parentSlug: folder.parentSlug)
                }
            }
            for (slug, entry) in registry.entries where !entry.isDeleted && local[slug] == nil && mirrored[slug] != nil {
                // It was here and is gone: a local deletion.
                registry.remove(slug)
            }
        }
        mirrored = store.registry.entries
    }

    private func apply(_ registry: FolderRegistry) {
        applying = true
        defer { applying = false; mirrored = registry.entries }
        let folders = FolderStore.shared
        for (slug, entry) in registry.entries {
            let existing = folders.existingFolder(slug: slug)
            if entry.isDeleted {
                if let existing, !SessionFolder.system.contains(existing) {
                    let affected = SessionStore.shared.sessions.filter { $0.folderSlug.lowercased() == slug }
                    if !affected.isEmpty {
                        Task { @MainActor in await SessionStore.shared.moveMany(affected, to: .inbox) }
                    }
                    folders.removeFolder(existing)
                    log.notice("Folder removed elsewhere: \(slug, privacy: .public)")
                }
                continue
            }
            if existing == nil {
                let added = folders.addFolder(named: entry.name)
                if let parent = entry.parentSlug { folders.setParent(added, to: parent) }
                log.notice("Folder from another device: \(entry.name, privacy: .public)")
            } else if let existing {
                if existing.name != entry.name { folders.renameInPlace(existing, to: entry.name) }
                if existing.parentSlug != entry.parentSlug { folders.setParent(existing, to: entry.parentSlug) }
            }
        }
    }
}
