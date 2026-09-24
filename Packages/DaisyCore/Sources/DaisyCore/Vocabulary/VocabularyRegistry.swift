//
//  VocabularyRegistry.swift
//  DaisyCore
//
//  The person's vocabulary — terms Daisy should spell their way, and
//  corrections for what the model keeps mishearing — on every device.
//  24.09: the Mac had it since 1.0.7; the phone had none, so a word
//  taught on the Mac was still wrong in every recording made on the
//  phone.
//
//  Same road as the folder list (`FolderRegistry`): settings, not
//  session data, so it rides in iCloud's key-value store under the one
//  identifier the Mac and the phone share. The store is whole-value
//  last-writer-wins, which two devices editing at once would lose to;
//  so every rule carries its own stamp, a deletion is a tombstone with a
//  stamp of its own, and every read MERGES — per rule, the newer wins.
//
//  Order matters to the Mac's editor (ties between equal-length
//  corrections go to the earlier row), so a rule also carries its
//  position. Two devices appending at once land on the same position;
//  the tie falls to the older rule, then the id — stable everywhere.
//

import Foundation

/// The rule as the registry carries it. The Mac app has its own
/// `DictationReplacement` with the same fields, and `DaisyCore.` names
/// this package's `DaisyCore` enum rather than the module — so the
/// Mac's bridge spells the shared one this way.
public typealias SharedDictationReplacement = DictationReplacement

public nonisolated struct VocabularyRegistry: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var rule: DictationReplacement
        public var position: Double
        public var updatedAt: Date
        /// Set when removed; the entry stays as a tombstone.
        public var deletedAt: Date?
        public var isDeleted: Bool { deletedAt != nil }
        /// Fields a newer version wrote; kept as they were.
        public var extra: [String: JSONValue] = [:]

        public init(rule: DictationReplacement, position: Double, updatedAt: Date = Date(), deletedAt: Date? = nil) {
            self.rule = rule; self.position = position; self.updatedAt = updatedAt; self.deletedAt = deletedAt
        }

        var stamp: Date { max(updatedAt, deletedAt ?? .distantPast) }

        private static let known: Set<String> = ["rule", "position", "updatedAt", "deletedAt"]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            rule = try c.decode(DictationReplacement.self, forKey: .init("rule"))
            position = try c.decodeIfPresent(Double.self, forKey: .init("position")) ?? 0
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .init("updatedAt")) ?? .distantPast
            deletedAt = try c.decodeIfPresent(Date.self, forKey: .init("deletedAt"))
            extra = c.extras(except: Self.known)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(extras: extra)
            try c.encode(rule, forKey: .init("rule"))
            try c.encode(position, forKey: .init("position"))
            try c.encode(updatedAt, forKey: .init("updatedAt"))
            try c.encodeIfPresent(deletedAt, forKey: .init("deletedAt"))
        }
    }

    public static let kvsKey = "daisy.vocabulary.v1"

    /// Rule id (uuidString) → entry, tombstones included.
    public var entries: [String: Entry] = [:]
    /// Top-level fields a newer version wrote; kept as they were.
    public var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["entries"]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

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

    /// The live rules in order.
    public var rules: [DictationReplacement] {
        entries.values
            .filter { !$0.isDeleted }
            .sorted { a, b in
                if a.position != b.position { return a.position < b.position }
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.rule.id.uuidString < b.rule.id.uuidString
            }
            .map(\.rule)
    }

    public func entry(_ id: UUID) -> Entry? { entries[id.uuidString] }

    // MARK: - Mutations (all stamp "now")

    /// Add or change a rule at a position.
    public mutating func upsert(_ rule: DictationReplacement, position: Double, at now: Date = Date()) {
        entries[rule.id.uuidString] = Entry(rule: rule, position: position, updatedAt: now)
    }

    /// Add a rule after every live one.
    public mutating func append(_ rule: DictationReplacement, at now: Date = Date()) {
        let last = entries.values.filter { !$0.isDeleted }.map(\.position).max() ?? -1
        upsert(rule, position: last + 1, at: now)
    }

    public mutating func remove(_ id: UUID, at now: Date = Date()) {
        guard var entry = entries[id.uuidString], !entry.isDeleted else { return }
        entry.deletedAt = now
        entries[id.uuidString] = entry
    }

    /// Mirror a whole ordered list into the registry: new or changed
    /// rules (text or place) are stamped; rules that were in `previous`
    /// and are not in `list` any more are tombstoned. Rules the list
    /// never had are left alone — they are another device's, not yet
    /// seen here.
    public mutating func mirror(_ list: [DictationReplacement], previous: Set<UUID>, at now: Date = Date()) {
        for (index, rule) in list.enumerated() {
            let position = Double(index)
            if let current = entries[rule.id.uuidString], !current.isDeleted,
               current.rule == rule, current.position == position { continue }
            upsert(rule, position: position, at: now)
        }
        let present = Set(list.map(\.id))
        for id in previous where !present.contains(id) { remove(id, at: now) }
    }

    // MARK: - Merge

    /// Per rule, the newer stamp wins; a tie keeps the local entry.
    public func merged(with remote: VocabularyRegistry) -> VocabularyRegistry {
        var out = self
        for (id, theirs) in remote.entries {
            if let mine = out.entries[id], mine.stamp >= theirs.stamp { continue }
            out.entries[id] = theirs
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

    public static func decode(_ data: Data) -> VocabularyRegistry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(VocabularyRegistry.self, from: data)
    }
}

/// The vocabulary in iCloud's key-value store, read merged and written
/// whole, with a copy in this device's defaults: the key-value store
/// is a sync channel, and a device signed out of iCloud still keeps its
/// words. One instance per app; the owner reacts to `onExternalChange`.
@MainActor
public final class VocabularyRegistryStore {
    public private(set) var registry: VocabularyRegistry
    public var onExternalChange: ((VocabularyRegistry) -> Void)?
    private let kvs = NSUbiquitousKeyValueStore.default
    private let defaults: UserDefaults
    private var observer: (any NSObjectProtocol)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var start = VocabularyRegistry()
        if let data = defaults.data(forKey: VocabularyRegistry.kvsKey), let local = VocabularyRegistry.decode(data) {
            start = local
        }
        if let data = kvs.data(forKey: VocabularyRegistry.kvsKey), let remote = VocabularyRegistry.decode(data) {
            start = start.merged(with: remote)
        }
        registry = start
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        kvs.synchronize()
    }

    /// Merge what iCloud has into ours; tell the owner when anything moved.
    public func pull() {
        guard let data = kvs.data(forKey: VocabularyRegistry.kvsKey), let remote = VocabularyRegistry.decode(data) else { return }
        let merged = registry.merged(with: remote)
        guard merged != registry else { return }
        registry = merged
        saveLocally()
        onExternalChange?(merged)
        if merged != remote { push() }
    }

    /// Apply a local mutation and write the merged result.
    public func update(_ mutate: (inout VocabularyRegistry) -> Void) {
        var next = registry
        mutate(&next)
        // Someone else may have written meanwhile: merge before writing.
        if let data = kvs.data(forKey: VocabularyRegistry.kvsKey), let remote = VocabularyRegistry.decode(data) {
            next = next.merged(with: remote)
        }
        guard next != registry else { return }
        registry = next
        saveLocally()
        push()
    }

    private func saveLocally() {
        guard let data = registry.encoded() else { return }
        defaults.set(data, forKey: VocabularyRegistry.kvsKey)
    }

    private func push() {
        guard let data = registry.encoded() else { return }
        kvs.set(data, forKey: VocabularyRegistry.kvsKey)
        kvs.synchronize()
    }
}
