//
//  UsageStats.swift
//  Daisy
//
//  Tiny local usage tracker powering the Home stat widgets (words/min,
//  total words, activity heatmap). Records one entry per finished
//  dictation and per finished recording: words produced + seconds spent.
//  Aggregated per local day so it stays small (one row per active day),
//  and it's the ONLY place these numbers live — dictations are ephemeral
//  and DictationHistory is a 24h/200-cap window, so neither total words
//  nor WPM is derivable from anything else.
//
//  100% local (UserDefaults JSON). Never leaves the Mac.
//

import Foundation
import Observation

@MainActor
@Observable
final class UsageStats {
    static let shared = UsageStats()

    enum Kind: Sendable { case dictation, recording }

    /// Per-day aggregate. `count` = dictations + recordings that day (drives
    /// the heatmap); `words`/`seconds` are the combined total; the
    /// `dictation*` fields are the DICTATION-only subset used for WPM (a
    /// meeting transcript is many speakers, so mixing it into WPM is
    /// meaningless — audit fix).
    struct DayStat: Codable, Sendable {
        var words: Int = 0
        var seconds: Double = 0
        var count: Int = 0
        var dictationWords: Int = 0
        var dictationSeconds: Double = 0
        /// Replacements the dictation dictionary actually made (a match
        /// that already had the canonical form doesn't count).
        var dictionaryFixes: Int = 0
        /// Words changed by the "polish in my voice" rewrite.
        var polishedWords: Int = 0

        init(words: Int = 0, seconds: Double = 0, count: Int = 0,
             dictationWords: Int = 0, dictationSeconds: Double = 0,
             dictionaryFixes: Int = 0, polishedWords: Int = 0) {
            self.words = words; self.seconds = seconds; self.count = count
            self.dictationWords = dictationWords; self.dictationSeconds = dictationSeconds
            self.dictionaryFixes = dictionaryFixes; self.polishedWords = polishedWords
        }

        // Tolerant decode — older persisted rows lack the newer fields.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            words = (try? c.decode(Int.self, forKey: .words)) ?? 0
            seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0
            count = (try? c.decode(Int.self, forKey: .count)) ?? 0
            dictationWords = (try? c.decode(Int.self, forKey: .dictationWords)) ?? 0
            dictationSeconds = (try? c.decode(Double.self, forKey: .dictationSeconds)) ?? 0
            dictionaryFixes = (try? c.decode(Int.self, forKey: .dictionaryFixes)) ?? 0
            polishedWords = (try? c.decode(Int.self, forKey: .polishedWords)) ?? 0
        }
    }

    struct PeriodSnapshot: Sendable {
        let totalWords: Int
        let totalSeconds: Double
        let totalCount: Int
        let totalDictationWords: Int
        let totalDictationSeconds: Double
        let totalDictionaryFixes: Int
        let totalPolishedWords: Int

        var totalFixes: Int { totalDictionaryFixes + totalPolishedWords }

        /// Weighted across the whole period. Averaging daily WPM would
        /// give a two-second dictation the same influence as an hour.
        var averageWPM: Int {
            let minutes = totalDictationSeconds / 60
            guard minutes >= 0.1 else { return 0 }
            return Int((Double(totalDictationWords) / minutes).rounded())
        }
    }

    private static let defaultsKey = "daisy.usageStats"

    /// Keyed by `yyyy-MM-dd` (local). Observable so the widgets refresh
    /// live as new dictations/recordings land.
    private(set) var days: [String: DayStat]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DayStat].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
    }

    // MARK: - Record

    /// Log one finished dictation/recording. No-op for empty output so a
    /// silent/aborted session doesn't inflate the streak or drag WPM.
    func record(words: Int, seconds: Double, kind: Kind) {
        guard words > 0 else { return }
        let key = Self.dayKey(for: Date())
        var stat = days[key] ?? DayStat()
        stat.words += words
        stat.seconds += max(0, seconds)
        stat.count += 1
        if kind == .dictation {
            stat.dictationWords += words
            stat.dictationSeconds += max(0, seconds)
        }
        days[key] = stat
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Backfill

    private static let backfillKey = "daisy.usageStats.didBackfill"

    /// One-time backfill from the existing Library so the Home widgets
    /// aren't empty for users who recorded plenty BEFORE the tracker
    /// shipped. Counts each stored session as a `.recording` (word count
    /// from its transcript, seconds from its duration), bucketed by its
    /// own day. Dictation history can't be backfilled (ephemeral), so WPM
    /// stays 0 until the first new dictation — correct, since WPM is
    /// dictation-only. Idempotent via a UserDefaults flag.
    func backfillIfNeeded(from sessions: [StoredSession], storageWasReachable: Bool) {
        guard !UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }
        // The gate is whether the STORAGE was readable, not whether the
        // list came back non-empty, and both halves of that matter:
        //
        //   • an unreachable folder (drive unmounted, bookmark gone)
        //     used to burn the one-shot flag on an empty list, leaving
        //     the Home widgets permanently blank;
        //   • but gating on "non-empty" instead would leave the flag
        //     unburned on a genuinely new install — and then the first
        //     recording, already counted live, would be backfilled on
        //     top of itself and every number for that day would double
        //     (review find, 2026-09-02).
        //
        // Reachable-and-empty is a real answer: nothing to backfill,
        // and we say so permanently.
        guard storageWasReachable else { return }
        UserDefaults.standard.set(true, forKey: Self.backfillKey)
        guard !sessions.isEmpty else { return }

        for s in sessions {
            let words = Self.wordCount(s.transcriptText)
            guard words > 0 else { continue }
            let key = Self.dayKey(for: s.startedAt)
            var stat = days[key] ?? DayStat()
            stat.words += words
            stat.seconds += Double(max(0, s.durationSec))
            stat.count += 1
            days[key] = stat
        }
        persist()
    }

    // MARK: - Derived

    /// Log fixes made on a dictation (dictionary replacements and/or
    /// voice-polish word changes). Separate from `record` because the
    /// dictionary pass runs later, in `DictationPaste`.
    func recordFixes(dictionary: Int = 0, polished: Int = 0) {
        guard dictionary > 0 || polished > 0 else { return }
        let key = Self.dayKey(for: Date())
        var stat = days[key] ?? DayStat()
        stat.dictionaryFixes += max(0, dictionary)
        stat.polishedWords += max(0, polished)
        days[key] = stat
        persist()
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }
    var totalCount: Int { days.values.reduce(0) { $0 + $1.count } }
    var totalDictationWords: Int { days.values.reduce(0) { $0 + $1.dictationWords } }
    var totalDictationSeconds: Double { days.values.reduce(0) { $0 + $1.dictationSeconds } }
    var totalDictionaryFixes: Int { days.values.reduce(0) { $0 + $1.dictionaryFixes } }
    var totalPolishedWords: Int { days.values.reduce(0) { $0 + $1.polishedWords } }
    var totalFixes: Int { totalDictionaryFixes + totalPolishedWords }

    func snapshot(period: DashboardPeriod, endingAt end: Date = Date()) -> PeriodSnapshot {
        let keys = Set(period.dayKeys(endingAt: end))
        let values = days.compactMap { keys.contains($0.key) ? $0.value : nil }
        return PeriodSnapshot(
            totalWords: values.reduce(0) { $0 + $1.words },
            totalSeconds: values.reduce(0) { $0 + $1.seconds },
            totalCount: values.reduce(0) { $0 + $1.count },
            totalDictationWords: values.reduce(0) { $0 + $1.dictationWords },
            totalDictationSeconds: values.reduce(0) { $0 + $1.dictationSeconds },
            totalDictionaryFixes: values.reduce(0) { $0 + $1.dictionaryFixes },
            totalPolishedWords: values.reduce(0) { $0 + $1.polishedWords }
        )
    }

    /// Words-per-minute of the user's own DICTATION only (not meeting
    /// transcripts, which mix every speaker). 0 until there's meaningful
    /// dictation audio.
    var averageWPM: Int {
        let minutes = totalDictationSeconds / 60
        guard minutes >= 0.1 else { return 0 }
        return Int((Double(totalDictationWords) / minutes).rounded())
    }

    /// Consecutive days with activity ending today (0 if today is empty).
    var currentStreak: Int {
        let cal = Calendar.current
        var streak = 0
        var day = cal.startOfDay(for: Date())
        while let stat = days[Self.dayKey(for: day)], stat.count > 0 {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Per-day activity counts keyed by start-of-day, for the heatmap.
    func dayCounts() -> [Date: Int] {
        var out: [Date: Int] = [:]
        for (key, stat) in days {
            if let date = Self.date(fromKey: key) { out[date] = stat.count }
        }
        return out
    }

    // MARK: - Helpers

    /// Word count that also handles CJK (no spaces between words): each
    /// CJK ideograph / kana / hangul syllable counts as one "word", while
    /// space-delimited runs count once each.
    nonisolated static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in s.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                count += 1
                inWord = true
            }
        }
        return count
    }

    nonisolated private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // CJK Ext A
             0x3040...0x30FF,   // Hiragana + Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    // Pure Calendar math instead of a shared DateFormatter — a stored
    // formatter on a @MainActor class can't be touched from nonisolated
    // funcs, and locally-created Calendar values carry no shared state.
    // Key format unchanged ("yyyy-MM-dd", local day) — compatible with
    // already-persisted stats.

    nonisolated static func dayKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return cal.date(from: c).map { cal.startOfDay(for: $0) }
    }
}
