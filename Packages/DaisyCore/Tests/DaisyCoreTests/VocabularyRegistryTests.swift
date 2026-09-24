//
//  VocabularyRegistryTests.swift
//  DaisyCoreTests
//
//  The vocabulary on every device (24.09): a word taught on the Mac
//  reaches the phone, and two devices editing at once lose nothing.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Vocabulary in iCloud: merged per rule")
struct VocabularyRegistryTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func term(_ word: String) -> DictationReplacement {
        DictationReplacement(kind: .term, to: word)
    }

    @Test func twoDevicesAddingAtOnceKeepBoth() {
        var mac = VocabularyRegistry()
        var phone = VocabularyRegistry()
        mac.append(term("Daisy"), at: t0)
        phone.append(term("Лакки"), at: t0.addingTimeInterval(5))
        let merged = mac.merged(with: phone)
        #expect(merged.rules.map(\.to) == ["Daisy", "Лакки"])      // same position: the older first
        #expect(phone.merged(with: mac).rules == merged.rules)       // the same on both devices
    }

    @Test func aDeletionIsNotUndoneByAStaleCopy() {
        var mac = VocabularyRegistry()
        let rule = term("SQL Editor")
        mac.append(rule, at: t0)
        let staleOnPhone = mac                                       // the phone saw it before
        mac.remove(rule.id, at: t0.addingTimeInterval(60))
        #expect(mac.merged(with: staleOnPhone).rules.isEmpty)
        #expect(staleOnPhone.merged(with: mac).rules.isEmpty)
    }

    @Test func theNewerEditWins() {
        var mac = VocabularyRegistry()
        var rule = DictationReplacement(kind: .correction, from: "дейзи", to: "Daisy")
        mac.append(rule, at: t0)
        var phone = mac
        rule.to = "Daisy app"
        phone.upsert(rule, position: 0, at: t0.addingTimeInterval(30))
        #expect(mac.merged(with: phone).rules.first?.to == "Daisy app")
    }

    @Test func mirroringAListStampsOnlyWhatChanged() {
        let a = term("Daisy"), b = term("Лакки"), c = term("SQL Editor")
        var registry = VocabularyRegistry()
        registry.mirror([a, b, c], previous: [], at: t0)
        #expect(registry.rules == [a, b, c])
        // Reordered and one removed, on the Mac:
        registry.mirror([c, a], previous: [a.id, b.id, c.id], at: t0.addingTimeInterval(10))
        #expect(registry.rules == [c, a])
        #expect(registry.entry(b.id)?.isDeleted == true)
        // A rule another device added and this list never saw survives:
        var other = registry
        other.append(term("Garmin"), at: t0.addingTimeInterval(20))
        var mine = registry.merged(with: other)
        mine.mirror([c, a], previous: [a.id, c.id], at: t0.addingTimeInterval(30))
        #expect(mine.rules.map(\.to).contains("Garmin"))
    }

    @Test func itSurvivesTheRoundTripAndKeepsUnknownFields() throws {
        var registry = VocabularyRegistry()
        registry.append(term("Daisy"), at: t0)
        registry.extra["future"] = .string("kept")
        let data = try #require(registry.encoded())
        let back = try #require(VocabularyRegistry.decode(data))
        #expect(back == registry)
    }
}
