//
//  DictationHistory.swift
//  Daisy
//
//  An on-device log of what the user dictated. Push-to-talk dictation is
//  otherwise ephemeral — `DictationPaste` writes the text to the
//  clipboard, pastes it, then reverts the clipboard ~10 s later — so once
//  the transcript lands in the user's field there is no record of it
//  anywhere. That's usually fine, but "wait, what did I just say?" / "I
//  dictated that into the wrong window" / "the paragraph from Tuesday"
//  have no recovery without this. The user can glance back and re-copy.
//
//  How long it is kept is the user's choice (2026-10-13): 24 hours,
//  7 days (the default), 30 days or always. It used to be a fixed 24
//  hours, and a person who came back after an update read the empty list
//  as data lost — the window, and the line in the history that names it,
//  are the answer to that. Shortening the window asks before anything
//  older goes (`DictationHistoryView`); nothing is deleted on its own
//  except by age and the `maxEntries` cap, as before.
//
//  Deliberately minimal and private:
//   - Local only. One JSON file, `dictation-history.json`, in Daisy's
//     Application Support folder (as on Windows) — never synced, never
//     sent anywhere. It used to be a UserDefaults blob; 30 days of
//     dictation is too much to keep in the preferences plist, which is
//     read whole at launch. The old blob moves to the file once.
//   - Self-pruning by age, on load and on every `record(_:)`.
//   - Bounded at `maxEntries` whatever the window, "always" included.
//   - Written off the main actor: `record` runs on the paste path,
//     before the text lands, and 2,000 entries are half a megabyte.
//
//  @MainActor: `record(_:)` is called on the MainActor-isolated
//  dictation paste path (`DictationPaste.prepare`) and the list is read
//  and cleared from the Dictation window (also MainActor).
//

import Foundation
import Observation
import os

/// One recorded dictation: the text that was pasted (dictionary already
/// applied) plus when it happened.
nonisolated struct DictationEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// The pasted text, exactly as it landed in the user's field
    /// (custom-vocabulary replacements already applied upstream).
    var text: String
    /// When the dictation was recorded.
    var date: Date
}

/// How long dictations are kept.
nonisolated enum DictationRetention: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case always

    static let `default`: DictationRetention = .week

    var id: String { rawValue }

    /// Age past which an entry goes; nil keeps it until the count cap.
    var interval: TimeInterval? {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .always: return nil
        }
    }
}

@MainActor
@Observable
final class DictationHistory {
    static let shared = DictationHistory()

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationHistory")

    /// Where the history lived before it moved to a file.
    nonisolated static let legacyDefaultsKey = "daisy.dictationHistory"
    nonisolated static let retentionKey = "daisy.dictationHistoryRetention"
    nonisolated static let fileName = "dictation-history.json"

    /// Hard cap on stored entries, independent of age. Newest kept.
    nonisolated static let maxEntries = 2000

    /// Newest-first list of recent dictations, always swept (age + cap).
    private(set) var entries: [DictationEntry] = []

    private(set) var retention: DictationRetention

    @ObservationIgnored
    private let fileURL: URL?
    /// Writes run one after another, each with the list as it was then.
    @ObservationIgnored
    private var lastWrite: Task<Bool, Never>?

    private init() {
        retention = UserDefaults.standard.string(forKey: Self.retentionKey)
            .flatMap(DictationRetention.init(rawValue:)) ?? .default
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        fileURL = support?
            .appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent(Self.fileName)

        // A missing or corrupt file starts empty rather than crashing —
        // the history is non-critical and a bad decode shouldn't take
        // down dictation.
        var restored: [DictationEntry] = []
        var migrated = false
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            restored = (try? JSONDecoder().decode([DictationEntry].self, from: data)) ?? []
            // A blob left by a move whose first write failed and a later
            // one succeeded: the file is the history now.
            UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
        } else if let data = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey) {
            restored = (try? JSONDecoder().decode([DictationEntry].self, from: data)) ?? []
            migrated = true
        }
        let swept = Self.swept(restored, retention: retention)
        entries = swept
        if migrated || swept.count != restored.count {
            persist()
        }
        if migrated {
            // Only once the file holds the entries; until then the blob
            // stays, so a failed first write loses nothing.
            let write = lastWrite
            Task { @MainActor in
                if await write?.value == true {
                    UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
                }
            }
        }
    }

    // MARK: - Mutation

    /// Log a dictation. The text should be the final pasted string (with
    /// the dictionary already applied) so the history matches what the
    /// user actually got. Whitespace-only / empty transcripts are ignored
    /// — there's nothing useful to re-copy.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Store the original text (not the trimmed copy) so leading/
        // trailing formatting the user dictated is preserved on re-copy.
        let entry = DictationEntry(text: text, date: Date())
        entries = Self.swept([entry] + entries, retention: retention)
        persist()
    }

    /// Drop the entire history. Used by the "Clear history" control.
    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        persist()
    }

    /// How many entries `retention` would remove right now — what the
    /// question before shortening the window counts.
    func entriesRemoved(by retention: DictationRetention) -> Int {
        entries.count - Self.swept(entries, retention: retention).count
    }

    /// Switch the window and apply it. The caller asks first when this
    /// removes anything (`entriesRemoved(by:)`).
    func setRetention(_ new: DictationRetention) {
        guard new != retention else { return }
        retention = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.retentionKey)
        let swept = Self.swept(entries, retention: new)
        if swept.count != entries.count {
            entries = swept
            persist()
        }
    }

    /// Apply the window now. Entries are otherwise swept only when one
    /// is added, so a list left open for days would keep showing what
    /// has expired; the history view calls this when it appears.
    func sweepExpired() {
        let swept = Self.swept(entries, retention: retention)
        if swept.count != entries.count {
            entries = swept
            persist()
        }
    }

    // MARK: - Sweep

    /// `list` without what is older than `retention` at `now`, newest
    /// first, bounded to `maxEntries`. Sorted defensively: callers
    /// prepend, but a hand-edited file might not be ordered.
    nonisolated static func swept(
        _ list: [DictationEntry],
        retention: DictationRetention,
        now: Date = Date()
    ) -> [DictationEntry] {
        var live = list
        if let interval = retention.interval {
            let cutoff = now.addingTimeInterval(-interval)
            live = live.filter { $0.date >= cutoff }
        }
        live.sort { $0.date > $1.date }
        return Array(live.prefix(maxEntries))
    }

    // MARK: - Persistence

    /// The list as it is now, written after any write before it. The
    /// task's value says whether this one landed.
    private func persist() {
        guard let fileURL else { return }
        let snapshot = entries
        let previous = lastWrite
        let log = log
        lastWrite = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: [.atomic])
                return true
            } catch {
                log.error("Couldn't persist dictation history: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }
}
