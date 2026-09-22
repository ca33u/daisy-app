//
//  FolderRegistry.swift
//  DaisyCore
//
//  backlog 9 Ф3-C: the project list is settings, not session data (§9),
//  so it rides in iCloud's key-value store, shared by the Mac and the
//  phone under one identifier. A session carries only its folder's
//  slug; this is where the slug becomes a name and a parent.
//
//  The store is whole-value last-writer-wins, which is not enough for
//  two devices editing at once: the registry therefore carries a stamp
//  per folder, and every read MERGES — per slug, the newer entry wins;
//  a deletion is a tombstone with its own stamp, so a folder removed on
//  the Mac does not come back from the phone's stale copy. §9's rule
//  ("an unknown slug recreates the project") still applies above this:
//  a session that names a deleted slug brings the folder back, with a
//  fresh stamp, on whichever device meets it.
//
//  Slug-changing renames are NOT a registry operation (a slug is the
//  identity): they are add-new + rewrite `daisy_folder` in every session
//  + tombstone-old, on the device that renames — exactly what the Mac
//  already does. The sessions then ride through CloudKit like any edit.
//

import Foundation

public nonisolated struct FolderRegistry: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Display name (case preserved); the slug is `name.lowercased()`.
        public var name: String
        public var parentSlug: String?
        public var updatedAt: Date
        /// Set when removed; the entry stays as a tombstone.
        public var deletedAt: Date?
        public var isDeleted: Bool { deletedAt != nil }
        public init(name: String, parentSlug: String? = nil, updatedAt: Date = Date(), deletedAt: Date? = nil) {
            self.name = name; self.parentSlug = parentSlug; self.updatedAt = updatedAt; self.deletedAt = deletedAt
        }
        var stamp: Date { max(updatedAt, deletedAt ?? .distantPast) }
    }

    public static let kvsKey = "daisy.folderRegistry.v1"
    public static let systemSlugs: Set<String> = ["inbox", "notes"]

    /// slug → entry (tombstones included).
    public var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public static func slug(for name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Live folders, roots before children, stable order by name.
    public var live: [(slug: String, entry: Entry)] {
        entries.filter { !$0.value.isDeleted && !Self.systemSlugs.contains($0.key) }
            .sorted { a, b in
                let ra = a.value.parentSlug == nil, rb = b.value.parentSlug == nil
                if ra != rb { return ra }
                return a.value.name.localizedCaseInsensitiveCompare(b.value.name) == .orderedAscending
            }
            .map { ($0.key, $0.value) }
    }

    public func entry(_ slug: String) -> Entry? {
        guard let e = entries[slug.lowercased()], !e.isDeleted else { return nil }
        return e
    }

    // MARK: - Mutations (all stamp "now")

    /// Add or revive; returns the slug.
    @discardableResult
    public mutating func upsert(name: String, parentSlug: String? = nil, at now: Date = Date()) -> String {
        let slug = Self.slug(for: name)
        guard !slug.isEmpty, !Self.systemSlugs.contains(slug) else { return slug.isEmpty ? "inbox" : slug }
        let parent = parentSlug?.lowercased()
        entries[slug] = Entry(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              parentSlug: parent == slug ? nil : parent, updatedAt: now, deletedAt: nil)
        return slug
    }

    public mutating func remove(_ slug: String, at now: Date = Date()) {
        let slug = slug.lowercased()
        guard var e = entries[slug] else { return }
        e.deletedAt = now
        entries[slug] = e
        // Children of a removed parent become roots, as on the Mac.
        for (child, var ce) in entries where ce.parentSlug == slug && !ce.isDeleted {
            ce.parentSlug = nil
            ce.updatedAt = now
            entries[child] = ce
        }
    }

    // MARK: - Merge

    /// Per slug, the newer stamp wins; a tie keeps the local entry.
    public func merged(with remote: FolderRegistry) -> FolderRegistry {
        var out = self
        for (slug, theirs) in remote.entries {
            if let mine = out.entries[slug], mine.stamp >= theirs.stamp { continue }
            out.entries[slug] = theirs
        }
        return out
    }

    // MARK: - Coding for the store

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    public static func decode(_ data: Data) -> FolderRegistry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(FolderRegistry.self, from: data)
    }
}

/// The iCloud key-value store, read merged and written whole. One
/// instance per app; the owner reacts to `onExternalChange`.
@MainActor
public final class FolderRegistryStore {
    public private(set) var registry: FolderRegistry
    public var onExternalChange: ((FolderRegistry) -> Void)?
    private let kvs = NSUbiquitousKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    public init() {
        registry = FolderRegistry()
        if let data = kvs.data(forKey: FolderRegistry.kvsKey), let stored = FolderRegistry.decode(data) {
            registry = stored
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        kvs.synchronize()
    }

    /// Merge what iCloud has into ours; tell the owner when anything moved.
    public func pull() {
        guard let data = kvs.data(forKey: FolderRegistry.kvsKey), let remote = FolderRegistry.decode(data) else { return }
        let merged = registry.merged(with: remote)
        guard merged != registry else { return }
        registry = merged
        onExternalChange?(merged)
        if merged != remote { push() }
    }

    /// Apply a local mutation and write the merged result.
    public func update(_ mutate: (inout FolderRegistry) -> Void) {
        var next = registry
        mutate(&next)
        // Someone else may have written meanwhile: merge before writing.
        if let data = kvs.data(forKey: FolderRegistry.kvsKey), let remote = FolderRegistry.decode(data) {
            next = next.merged(with: remote)
        }
        registry = next
        push()
    }

    private func push() {
        guard let data = registry.encoded() else { return }
        kvs.set(data, forKey: FolderRegistry.kvsKey)
        kvs.synchronize()
    }
}
