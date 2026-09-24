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
        var local = current
        let deleted = Set(registry.entries.values.filter(\.isDeleted).map(\.rule.id))
        local.removeAll { deleted.contains($0.id) }
        for rule in registry.rules {
            let mine = Self.toLocal(rule)
            if let index = local.firstIndex(where: { $0.id == rule.id }) {
                local[index] = mine
            } else {
                local.append(mine)
                log.notice("Vocabulary from another device: \(rule.kind.rawValue, privacy: .public)")
            }
        }
        // The registry's order for what it knows; this Mac's own place
        // for the rest, which `localChanged` sends up next.
        let positions = Dictionary(uniqueKeysWithValues: registry.entries.values.filter { !$0.isDeleted }.map { ($0.rule.id, $0.position) })
        local = local.enumerated()
            .sorted { (positions[$0.element.id] ?? Double($0.offset), $0.offset) < (positions[$1.element.id] ?? Double($1.offset), $1.offset) }
            .map(\.element)
        if local != current { DictationDictionary.shared.replaceAll(local) }
        mirrored = Set(local.map(\.id))
    }

    // MARK: - The Mac's rule ⇄ the shared one (same fields, two modules)

    static func toShared(_ rule: DictationReplacement) -> SharedDictationReplacement {
        SharedDictationReplacement(id: rule.id, kind: rule.kind == .term ? .term : .correction,
                                       from: rule.from, to: rule.to, caseSensitive: rule.caseSensitive)
    }

    static func toLocal(_ rule: SharedDictationReplacement) -> DictationReplacement {
        DictationReplacement(id: rule.id, kind: rule.kind == .term ? .term : .correction,
                             from: rule.from, to: rule.to, caseSensitive: rule.caseSensitive)
    }
}
