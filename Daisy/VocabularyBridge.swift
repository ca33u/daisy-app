//
//  VocabularyBridge.swift
//  Daisy
//
//  `DictationDictionary` (UserDefaults, this Mac) ⇄ `VocabularyRegistry`
//  (iCloud key-value store, every device) — 24.09, the vocabulary on the
//  phone too. The dictionary stays the source of truth for the editor
//  and the dictation path; the bridge mirrors each local change into
//  the registry and applies what other devices did, the way
//  `FolderRegistryBridge` does for folders.
//

import DaisyCore
import Foundation
import os

@MainActor
final class VocabularyBridge {
    static let shared = VocabularyBridge()

    private let store = VocabularyRegistryStore()
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationDictionary")
    /// The ids this Mac's list held when it was last mirrored — what a
    /// rule missing from the list now was deleted from.
    private var mirrored: Set<UUID> = []
    private var applying = false
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        store.onExternalChange = { [weak self] registry in self?.apply(registry) }
        // First run: what the registry has comes down, what only this
        // Mac has goes up.
        apply(store.registry)
        localChanged()
    }

    /// Called by `DictationDictionary` after every persist.
    func localChanged() {
        guard started, !applying else { return }
        let list = DictationDictionary.shared.replacements.map(Self.toShared(_:))
        store.update { $0.mirror(list, previous: mirrored) }
        mirrored = Set(list.map(\.id))
    }

    private func apply(_ registry: VocabularyRegistry) {
        applying = true
        defer { applying = false }
        let current = DictationDictionary.shared.replacements
        let local = Self.merge(local: current, with: registry)
        let added = Set(local.map(\.id)).subtracting(current.map(\.id)).count
        if added > 0 { log.notice("Vocabulary from another device: \(added, privacy: .public) new rule(s)") }
        if local != current { DictationDictionary.shared.replaceAll(local) }
        mirrored = Set(local.map(\.id))
    }

    /// This Mac's list after what the registry says: rules another
    /// device deleted go, rules it added or changed come in, and the
    /// order is the registry's for what it knows — this Mac's own place
    /// for rules it has not seen yet, which `localChanged` sends up next.
    nonisolated static func merge(local current: [DictationReplacement], with registry: VocabularyRegistry) -> [DictationReplacement] {
        var local = current
        let deleted = Set(registry.entries.values.filter(\.isDeleted).map(\.rule.id))
        local.removeAll { deleted.contains($0.id) }
        for rule in registry.rules {
            let mine = toLocal(rule)
            if let index = local.firstIndex(where: { $0.id == rule.id }) {
                local[index] = mine
            } else {
                local.append(mine)
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: registry.entries.values.filter { !$0.isDeleted }.map { ($0.rule.id, $0.position) })
        return local.enumerated()
            .sorted { (positions[$0.element.id] ?? Double($0.offset), $0.offset) < (positions[$1.element.id] ?? Double($1.offset), $1.offset) }
            .map(\.element)
    }

    // MARK: - The Mac's rule ⇄ the shared one (same fields, two modules)

    nonisolated static func toShared(_ rule: DictationReplacement) -> SharedDictationReplacement {
        SharedDictationReplacement(id: rule.id, kind: rule.kind == .term ? .term : .correction,
                                       from: rule.from, to: rule.to, caseSensitive: rule.caseSensitive)
    }

    nonisolated static func toLocal(_ rule: SharedDictationReplacement) -> DictationReplacement {
        DictationReplacement(id: rule.id, kind: rule.kind == .term ? .term : .correction,
                             from: rule.from, to: rule.to, caseSensitive: rule.caseSensitive)
    }
}
