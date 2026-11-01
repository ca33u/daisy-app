//
//  AXWriteMemory.swift
//  Daisy
//
//  How each app took Daisy's Accessibility writes, per app version, kept
//  between launches (01.11.2026). Telegram applies a write a beat late —
//  on macOS 27 it answers «success», on macOS 15 «error» — and the field
//  still shows the old text on the read right after. Daisy took that for a
//  refusal, typed the words again, and every dictation landed twice
//  (Egor 31.10; a tester on macOS 15.3, 01.11). An app that ignores
//  writes for good (Electron, web views) would cost a wait on every
//  dictation if it weren't remembered.
//
//  The rules are pure and take their UserDefaults, so tests never touch
//  the real preferences.
//

import Foundation

nonisolated struct AXWriteMemory {
    struct Entry: Codable, Equatable {
        /// Writes that never showed up, with the field readable and
        /// without the text before. Reset by any write that landed, right
        /// away or late.
        var ignored = 0
        /// The slowest write seen landing late, in ms.
        var lateMs: Int?
        /// A write showed up only after Daisy had already typed or pasted
        /// the text — the field held it twice.
        var landedAfterFallback = false
        /// When the last miss was counted: a skip is tried again after a
        /// week, so one bad day doesn't last until the app updates.
        var lastIgnored: Date?
    }

    static let defaultsKey = "daisy.axWriteMemory"
    /// How long a write gets to show up in an app Daisy knows nothing
    /// about, before it types instead.
    static let firstWait: TimeInterval = 0.6
    /// The longest Daisy waits, for an app whose writes once landed after
    /// the fallback.
    static let longestWait: TimeInterval = 2.0
    /// Two writes that never showed up: from then on the app is typed into
    /// straight away.
    static let ignoredLimit = 2
    /// How long a skip lasts before Daisy tries the write again.
    static let skipLasts: TimeInterval = 7 * 24 * 60 * 60

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One app at one version: an update may change how it takes writes.
    static func key(bundleID: String, version: String?) -> String {
        "\(bundleID)|\(version ?? "?")"
    }

    func entry(for key: String) -> Entry {
        load()[key] ?? Entry()
    }

    /// Skip the write and type at once: it was ignored twice, never seen
    /// landing, and the last miss is under a week old.
    static func skipsWrite(_ entry: Entry, now: Date = Date()) -> Bool {
        guard entry.ignored >= ignoredLimit, entry.lateMs == nil, !entry.landedAfterFallback,
              let last = entry.lastIgnored else { return false }
        return now.timeIntervalSince(last) < skipLasts
    }

    /// How long to watch the field for the write before falling back.
    static func wait(for entry: Entry) -> TimeInterval {
        if entry.landedAfterFallback { return longestWait }
        if let ms = entry.lateMs { return min(longestWait, max(firstWait, Double(ms) * 3 / 1000)) }
        return firstWait
    }

    func recordLate(_ ms: Int, for key: String) {
        update(key) { $0.lateMs = max($0.lateMs ?? 0, ms); $0.ignored = 0 }
    }

    /// A write showed up right away: misses before it were chance.
    func recordLanded(for key: String) {
        guard entry(for: key).ignored > 0 else { return }
        update(key) { $0.ignored = 0 }
    }

    func recordIgnored(for key: String, at date: Date = Date()) {
        update(key) { $0.ignored += 1; $0.lastIgnored = date }
    }

    func recordLandedAfterFallback(for key: String) {
        update(key) { $0.landedAfterFallback = true; $0.ignored = 0 }
    }

    /// The text is in the field twice more than it was before: the write
    /// came in after the fallback had typed or pasted it.
    static func landedTwice(before: String, after: String, text: String) -> Bool {
        let needle = comparable(text)
        guard needle.count >= 2 else { return false }
        return occurrences(of: needle, in: comparable(after)) - occurrences(of: needle, in: comparable(before)) >= 2
    }

    /// Text as a field may store it: \r\n and \r as \n, the ends'
    /// whitespace off.
    static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func occurrences(of text: String, in value: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        var range = value.startIndex..<value.endIndex
        while let found = value.range(of: text, range: range) {
            count += 1
            range = found.upperBound..<value.endIndex
        }
        return count
    }

    // MARK: - Storage

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    private func update(_ key: String, _ change: (inout Entry) -> Void) {
        var map = load()
        // The same app at an older version says nothing about this one.
        let app = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
        for old in map.keys where old != key && old.hasPrefix(app + "|") { map[old] = nil }
        var entry = map[key] ?? Entry()
        change(&entry)
        map[key] = entry
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
