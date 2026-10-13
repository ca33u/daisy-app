//
//  DictationHistoryTests.swift
//  DaisyTests
//
//  The dictation history keeps what the chosen window allows (24 h,
//  7 days, 30 days, always), newest first, never more than the cap.
//

import Foundation
import Testing
@testable import Daisy

struct DictationHistoryTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func entry(daysAgo: Double) -> DictationEntry {
        DictationEntry(text: "\(daysAgo)", date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func eachWindowKeepsItsAge() {
        let list = [0.5, 2, 10, 40, 400].map(entry(daysAgo:))
        func kept(_ r: DictationRetention) -> [String] {
            DictationHistory.swept(list, retention: r, now: now).map(\.text)
        }
        #expect(kept(.day) == ["0.5"])
        #expect(kept(.week) == ["0.5", "2.0"])
        #expect(kept(.month) == ["0.5", "2.0", "10.0"])
        #expect(kept(.always) == ["0.5", "2.0", "10.0", "40.0", "400.0"])
    }

    @Test func newestFirstAndCapped() {
        let list = (0..<(DictationHistory.maxEntries + 5)).reversed().map { entry(daysAgo: Double($0) / 1000) }
        let swept = DictationHistory.swept(list, retention: .always, now: now)
        #expect(swept.count == DictationHistory.maxEntries)
        #expect(swept.first?.text == "0.0")
        #expect(zip(swept, swept.dropFirst()).allSatisfy { $0.date >= $1.date })
    }

    @Test func defaultIsSevenDays() {
        #expect(DictationRetention.default == .week)
    }
}
