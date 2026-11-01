//
//  AXWriteMemoryTests.swift
//  DaisyTests
//
//  How Daisy remembers apps that take an Accessibility write late, or not
//  at all (01.11: Telegram took every dictation twice).
//

import Foundation
import Testing
@testable import Daisy

struct AXWriteMemoryTests {
    /// A suite of its own per test: the real preferences are never touched.
    private func memory() -> (AXWriteMemory, UserDefaults, String) {
        let suite = "AXWriteMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AXWriteMemory(defaults: defaults), defaults, suite)
    }

    @Test("An app Daisy knows nothing about gets the first wait and a write")
    func unknownApp() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let entry = m.entry(for: AXWriteMemory.key(bundleID: "ru.keepcoder.Telegram", version: "13.1"))
        #expect(entry == AXWriteMemory.Entry())
        #expect(!AXWriteMemory.skipsWrite(entry))
        #expect(AXWriteMemory.wait(for: entry) == AXWriteMemory.firstWait)
    }

    @Test("Ignored twice and never seen landing: typed straight away")
    func ignoredTwice() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let key = AXWriteMemory.key(bundleID: "com.anthropic.claudefordesktop", version: "1.0")
        m.recordIgnored(for: key)
        #expect(!AXWriteMemory.skipsWrite(m.entry(for: key)))
        m.recordIgnored(for: key)
        #expect(AXWriteMemory.skipsWrite(m.entry(for: key)))
    }

    @Test("A write that landed late is waited for, three times as long, within the bounds")
    func landsLate() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let key = AXWriteMemory.key(bundleID: "ru.keepcoder.Telegram", version: "13.1")
        m.recordIgnored(for: key)
        m.recordLate(400, for: key)
        let entry = m.entry(for: key)
        #expect(entry.ignored == 0)
        #expect(entry.lateMs == 400)
        #expect(abs(AXWriteMemory.wait(for: entry) - 1.2) < 0.0001)
        m.recordLate(100, for: key)
        #expect(m.entry(for: key).lateMs == 400, "the slowest one is kept")
        m.recordLate(5000, for: key)
        #expect(AXWriteMemory.wait(for: m.entry(for: key)) == AXWriteMemory.longestWait)
        m.recordIgnored(for: key); m.recordIgnored(for: key)
        #expect(!AXWriteMemory.skipsWrite(m.entry(for: key)), "an app seen taking writes keeps getting them")
    }

    @Test("A write that came in after the fallback gets the longest wait from then on")
    func landedAfterFallback() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let key = AXWriteMemory.key(bundleID: "ru.keepcoder.Telegram", version: "13.1")
        m.recordIgnored(for: key)
        m.recordLandedAfterFallback(for: key)
        let entry = m.entry(for: key)
        #expect(entry.ignored == 0)
        #expect(AXWriteMemory.wait(for: entry) == AXWriteMemory.longestWait)
        #expect(!AXWriteMemory.skipsWrite(entry))
    }

    @Test("A new version of the app starts over, and the old one is dropped")
    func perVersion() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let old = AXWriteMemory.key(bundleID: "com.example.app", version: "1")
        let new = AXWriteMemory.key(bundleID: "com.example.app", version: "2")
        let other = AXWriteMemory.key(bundleID: "com.example.other", version: "1")
        m.recordIgnored(for: old); m.recordIgnored(for: old)
        m.recordIgnored(for: other)
        #expect(m.entry(for: new) == AXWriteMemory.Entry())
        m.recordLate(200, for: new)
        #expect(m.entry(for: old) == AXWriteMemory.Entry())
        #expect(m.entry(for: other).ignored == 1)
    }

    @Test("It lasts across instances on the same defaults")
    func persists() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let key = AXWriteMemory.key(bundleID: "ru.keepcoder.Telegram", version: nil)
        m.recordLate(300, for: key)
        #expect(AXWriteMemory(defaults: d).entry(for: key).lateMs == 300)
    }

    @Test("Text in the field twice more than before is a double landing", arguments: [
        ("Привет", "Привет", "ПриветПривет", false),
        ("", "Привет", "ПриветПривет", true),
        ("", "Привет", "Привет", false),
        ("Привет ", "Привет", "Привет ПриветПривет", true),
        ("", "a", "aa", false),
    ])
    func landedTwice(before: String, text: String, after: String, expected: Bool) {
        #expect(AXWriteMemory.landedTwice(before: before, after: after, text: text) == expected)
    }

    @Test("A skip is tried again after a week")
    func skipExpires() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let key = AXWriteMemory.key(bundleID: "com.example.electron", version: "1")
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        m.recordIgnored(for: key, at: then); m.recordIgnored(for: key, at: then)
        let entry = m.entry(for: key)
        #expect(AXWriteMemory.skipsWrite(entry, now: then.addingTimeInterval(60)))
        #expect(!AXWriteMemory.skipsWrite(entry, now: then.addingTimeInterval(AXWriteMemory.skipLasts + 1)))
    }

    @Test("A write that showed up right away clears earlier misses")
    func landedClearsMisses() {
        let (m, d, suite) = memory(); defer { d.removePersistentDomain(forName: suite) }
        let key = AXWriteMemory.key(bundleID: "com.apple.Safari", version: "26")
        m.recordLanded(for: key)
        #expect(d.data(forKey: AXWriteMemory.defaultsKey) == nil, "nothing written while there is nothing to clear")
        m.recordIgnored(for: key)
        m.recordLanded(for: key)
        m.recordIgnored(for: key)
        #expect(!AXWriteMemory.skipsWrite(m.entry(for: key)), "two misses weeks apart with good writes between don't add up")
    }

    @Test("A field's own line breaks and trimmed ends still count as the same text")
    func comparable() {
        #expect(AXWriteMemory.comparable("строка\r\nвторая\r") == "строка\nвторая")
        #expect(AXWriteMemory.landedTwice(before: "", after: "один\rдваодин\rдва", text: "один\nдва"))
    }

    @Test("Occurrences don't overlap")
    func occurrences() {
        #expect(AXWriteMemory.occurrences(of: "aa", in: "aaaa") == 2)
        #expect(AXWriteMemory.occurrences(of: "да", in: "Да, да") == 1)
        #expect(AXWriteMemory.occurrences(of: "", in: "abc") == 0)
    }
}
