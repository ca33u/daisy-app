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
//  identity here): they are add-new + rewrite `daisy_folder` in every
//  session + tombstone-old, on the device that renames — exactly what the
//  Mac already does. The sessions then ride through CloudKit like any edit.
//
//  Backlog 41: the slug is what sessions carry, but readers outside Daisy
//  (`.linked-source.json`) need a project to keep one identity through a
//  rename. Every entry therefore carries a stable `id`: the new slug of a
//  rename takes the old one's. Two devices that gave out ids to the same
//  live project before they met settle on the earlier one, whichever entry
//  is newer otherwise. A tombstone never hands its id to a live entry:
//  the slug a rename left may be a new project's by now.
//

import Foundation

/// Backlog 24 М-8: where a folder's work is tracked — a step from one of
/// its meetings becomes an issue there through a prefilled link. Every
/// field optional; nothing here is a credential.
public nonisolated struct ProjectContext: Codable, Sendable, Equatable {
    /// GitHub `owner/name`.
    public var repo: String?
    /// Linear team key (`ENG`).
    public var linearTeam: String?
    /// Jira site, `https://acme.atlassian.net`.
    public var jiraBase: String?
    /// Jira project id (the number, `pid`).
    public var jiraProjectID: String?
    /// Jira issue type id; the site's default when empty.
    public var jiraIssueType: String?
    /// 03.10.2026: what the owner wants every summary of this project to
    /// know — who is who, terms, what the work is about (`ProjectMemory`).
    public var notes: String?
    /// False when summaries of this project must NOT be told about its
    /// earlier meetings; nil and true mean they are.
    public var memory: Bool?

    public init(repo: String? = nil, linearTeam: String? = nil, jiraBase: String? = nil,
                jiraProjectID: String? = nil, jiraIssueType: String? = nil,
                notes: String? = nil, memory: Bool? = nil) {
        self.repo = repo; self.linearTeam = linearTeam; self.jiraBase = jiraBase
        self.jiraProjectID = jiraProjectID; self.jiraIssueType = jiraIssueType
        self.notes = notes; self.memory = memory
    }

    public var usesMemory: Bool { memory != false }

    public var isEmpty: Bool {
        [repo, linearTeam, jiraBase, jiraProjectID, notes].allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && memory != false
    }
}

public nonisolated struct FolderRegistry: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Display name (case preserved); the slug is `name.lowercased()`.
        public var name: String
        public var parentSlug: String?
        public var updatedAt: Date
        /// Set when removed; the entry stays as a tombstone.
        public var deletedAt: Date?
        public var isDeleted: Bool { deletedAt != nil }
        /// Backlog 24 М-8: the folder's trackers.
        public var project: ProjectContext?
        /// Backlog 41: the project's stable id, unchanged by renames.
        /// Nil only in entries an older version wrote.
        public var id: String?
        /// When `id` was given out: of two ids for one slug, the earlier wins.
        public var idAssignedAt: Date?
        /// Fields a newer version wrote; kept as they were.
        public var extra: [String: JSONValue] = [:]
        public init(name: String, parentSlug: String? = nil, updatedAt: Date = Date(), deletedAt: Date? = nil,
                    project: ProjectContext? = nil, id: String? = nil, idAssignedAt: Date? = nil) {
            self.name = name; self.parentSlug = parentSlug; self.updatedAt = updatedAt; self.deletedAt = deletedAt
            self.project = project; self.id = id; self.idAssignedAt = idAssignedAt
        }
        var stamp: Date { max(updatedAt, deletedAt ?? .distantPast) }

        /// Orders ids for the merge: the earlier given out first, a missing
        /// one last, the string itself breaking a tie — so both sides pick
        /// the same.
        fileprivate func idPrecedes(_ other: Entry) -> Bool {
            guard let id else { return false }
            guard let otherID = other.id else { return true }
            let mine = idAssignedAt ?? .distantFuture, theirs = other.idAssignedAt ?? .distantFuture
            return mine != theirs ? mine < theirs : id < otherID
        }

        private static let known: Set<String> = ["name", "parentSlug", "updatedAt", "deletedAt", "project", "id", "idAssignedAt"]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            name = try c.decode(String.self, forKey: .init("name"))
            parentSlug = try c.decodeIfPresent(String.self, forKey: .init("parentSlug"))
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .init("updatedAt")) ?? .distantPast
            deletedAt = try c.decodeIfPresent(Date.self, forKey: .init("deletedAt"))
            project = try? c.decodeIfPresent(ProjectContext.self, forKey: .init("project"))
            id = try c.decodeIfPresent(String.self, forKey: .init("id"))
            idAssignedAt = try c.decodeIfPresent(Date.self, forKey: .init("idAssignedAt"))
            extra = c.extras(except: Self.known)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(extras: extra)
            try c.encode(name, forKey: .init("name"))
            try c.encodeIfPresent(parentSlug, forKey: .init("parentSlug"))
            try c.encode(updatedAt, forKey: .init("updatedAt"))
            try c.encodeIfPresent(deletedAt, forKey: .init("deletedAt"))
            try c.encodeIfPresent(project, forKey: .init("project"))
            try c.encodeIfPresent(id, forKey: .init("id"))
            try c.encodeIfPresent(idAssignedAt, forKey: .init("idAssignedAt"))
        }
    }

    /// Top-level fields a newer version wrote; kept as they were.
    public var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["entries"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        entries = try c.decodeIfPresent([String: Entry].self, forKey: .init("entries")) ?? [:]
        extra = c.extras(except: Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(extras: extra)
        try c.encode(entries, forKey: .init("entries"))
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
    ///
    /// `id` is the device's own stable id for the project. A live entry
    /// keeps the id it has (the device adopts it from the registry); an
    /// entry that has none takes this one — with the time it was given out
    /// when another entry already carries it (the new slug of a rename) —
    /// or, without one, the id of the tombstone it revives or a new one.
    @discardableResult
    public mutating func upsert(name: String, parentSlug: String? = nil, id: String? = nil, at now: Date = Date()) -> String {
        let slug = Self.slug(for: name)
        guard !slug.isEmpty, !Self.systemSlugs.contains(slug) else { return slug.isEmpty ? "inbox" : slug }
        let parent = parentSlug?.lowercased()
        let previous = entries[slug]
        // A rename or a revival keeps what the folder carried (М-8's trackers,
        // a newer version's fields).
        var entry = Entry(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                          parentSlug: parent == slug ? nil : parent, updatedAt: now, deletedAt: nil,
                          project: previous?.project)
        entry.extra = previous?.extra ?? [:]
        if let previous, !previous.isDeleted, let kept = previous.id {
            entry.id = kept
            entry.idAssignedAt = previous.idAssignedAt
        } else if let id {
            entry.id = id
            entry.idAssignedAt = entries.values.first { $0.id == id }?.idAssignedAt ?? now
        } else if let revived = previous?.id, self.slug(forID: revived) == nil {
            // §9 brings the project back — unless the id lives on under
            // another slug (the project was renamed), when this is a new one.
            entry.id = revived
            entry.idAssignedAt = previous?.idAssignedAt
        } else {
            entry.id = UUID().uuidString
            entry.idAssignedAt = now
        }
        entries[slug] = entry
        return slug
    }

    /// The live entry carrying this stable id, if any.
    public func slug(forID id: String) -> String? {
        entries.first { !$0.value.isDeleted && $0.value.id == id }?.key
    }

    /// Backlog 24 М-8: the folder's trackers; empty clears them.
    public mutating func setProject(_ project: ProjectContext?, for slug: String, at now: Date = Date()) {
        let slug = slug.lowercased()
        guard var entry = entries[slug], !entry.isDeleted else { return }
        entry.project = project?.isEmpty == true ? nil : project
        entry.updatedAt = now
        entries[slug] = entry
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

    /// Per slug, the newer stamp wins; a tie keeps the local entry. The
    /// stable id of a live project is settled apart from that: the earlier
    /// given out wins on both sides, so two devices that each gave it an
    /// id agree — passing over an id another live project carries on
    /// either side (it was renamed away, and this is a new project under
    /// the old name) for the other one. Between a live entry and a
    /// tombstone the winner keeps its own — the tombstone's may belong to
    /// the renamed project now.
    public func merged(with remote: FolderRegistry) -> FolderRegistry {
        var out = self
        for (slug, theirs) in remote.entries {
            guard let mine = out.entries[slug] else {
                out.entries[slug] = theirs
                continue
            }
            var winner = mine.stamp >= theirs.stamp ? mine : theirs
            if mine.isDeleted == theirs.isDeleted {
                let byAge = theirs.idPrecedes(mine) ? [theirs, mine] : [mine, theirs]
                let carriedElsewhere = { (entry: Entry) -> Bool in
                    guard let id = entry.id else { return true }
                    return [self, remote].contains { $0.entries.contains { $0.key != slug && !$0.value.isDeleted && $0.value.id == id } }
                }
                // Neither free: the winner keeps its own.
                if let idSource = byAge.first(where: { !carriedElsewhere($0) }) {
                    winner.id = idSource.id
                    winner.idAssignedAt = idSource.idAssignedAt
                }
            }
            out.entries[slug] = winner
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
