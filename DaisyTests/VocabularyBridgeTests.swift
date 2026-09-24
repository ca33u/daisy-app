//
//  VocabularyBridgeTests.swift
//  DaisyTests
//
//  The phone → Mac half of the vocabulary sync (24.09): what the Mac's
//  list becomes when the registry brings another device's changes.
//

import struct DaisyCore.VocabularyRegistry
import Foundation
import Testing
@testable import Daisy

@Suite("Vocabulary from the phone lands in the Mac's list")
struct VocabularyBridgeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func term(_ word: String) -> DictationReplacement {
        DictationReplacement(kind: .term, to: word)
    }

    @Test func aWordAddedOnThePhoneAppearsAtTheEnd() {
        let mine = [term("Daisy"), term("Лакки")]
        var registry = VocabularyRegistry()
        registry.mirror(mine.map(VocabularyBridge.toShared), previous: [], at: t0)
        registry.append(VocabularyBridge.toShared(term("Garmin")), at: t0.addingTimeInterval(60))
        let merged = VocabularyBridge.merge(local: mine, with: registry)
        #expect(merged.map(\.to) == ["Daisy", "Лакки", "Garmin"])
    }

    @Test func aWordDeletedOnThePhoneGoes() {
        let mine = [term("Daisy"), term("SQL Editor")]
        var registry = VocabularyRegistry()
        registry.mirror(mine.map(VocabularyBridge.toShared), previous: [], at: t0)
        registry.remove(mine[1].id, at: t0.addingTimeInterval(60))
        #expect(VocabularyBridge.merge(local: mine, with: registry).map(\.to) == ["Daisy"])
    }

    @Test func anEditOnThePhoneReplacesTheRuleInPlace() {
        var fix = DictationReplacement(kind: .correction, from: "лаки", to: "Лакки")
        let mine = [term("Daisy"), fix]
        var registry = VocabularyRegistry()
        registry.mirror(mine.map(VocabularyBridge.toShared), previous: [], at: t0)
        fix.to = "Lucky"
        registry.upsert(VocabularyBridge.toShared(fix), position: 1, at: t0.addingTimeInterval(60))
        let merged = VocabularyBridge.merge(local: mine, with: registry)
        #expect(merged.count == 2)
        #expect(merged[1].id == fix.id && merged[1].to == "Lucky")
    }

    @Test func aMacRuleTheRegistryHasNotSeenStaysWhereItIs() {
        // Added on this Mac a moment before the phone's change arrived.
        let old = term("Daisy"), fresh = term("Notion")
        var registry = VocabularyRegistry()
        registry.mirror([VocabularyBridge.toShared(old)], previous: [], at: t0)
        let merged = VocabularyBridge.merge(local: [old, fresh], with: registry)
        #expect(merged.map(\.to) == ["Daisy", "Notion"])
    }
}
