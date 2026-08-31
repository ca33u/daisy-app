//
//  ActionItemStore.swift
//  Daisy
//
//  Open-loop tracking over the action items the summarizer already
//  extracts. Summaries only store flat strings; this store gives each
//  item a stable identity (sessionID + index), remembers which ones the
//  user checked off or dismissed, and exposes the OPEN set — the raw
//  material for the morning brief ("you still owe Maria the quote").
//  States persist in UserDefaults keyed by item id; the item list itself
//  is always rebuilt from the session corpus, so re-summarizing a
//  session naturally refreshes its items.
//

import Foundation
import Observation

struct TrackedActionItem: Identifiable, Sendable, Equatable {
    /// Stable identity: "<sessionID>#<index>" — survives app restarts as
    /// long as the summary isn't regenerated (acceptable: a re-summary
    /// means the items themselves changed).
    let id: String
    let text: String
    let sessionID: String
    let sessionTitle: String
    let sessionDate: Date
    /// When the user checked it off, or nil if still open. Drives the
    /// "done-today stays struck at the bottom, cleared on the next day"
    /// behavior — a bare Bool couldn't tell today's dones from old ones.
    var doneAt: Date?
    var isDone: Bool { doneAt != nil }
}

@MainActor
@Observable
final class ActionItemStore {
    static let shared = ActionItemStore()

    /// Items from the recent window, newest session first. Includes done
    /// ones (UI shows them struck-through until the window slides past).
    private(set) var items: [TrackedActionItem] = []

    /// How far back to harvest items. Old promises either got done or
    /// went stale — two weeks keeps the list honest.
    private static let windowDays = 14

    /// How long a done-stamp outlives the item it belongs to. Pruning
    /// used to be "not in the rebuilt list ⇒ delete the stamp", which
    /// turned every partial corpus into data loss: on a cold launch the
    /// day card's `.task` (MorningBriefStore.prepare) can rebuild from an
    /// EMPTY SessionStore before HomeView's refresh lands, and that wiped
    /// every checkmark the user had ticked (Egor, 2026-08-31 — "закрываю
    /// задачу, перезапускаю, снова не выполнено"). Age is the only safe
    /// prune signal: it can't be faked by a corpus that hasn't loaded.
    private static let stateRetentionDays = 90
    private static let stateKey = "daisy.actionItemStates"          // legacy [String: Bool]
    private static let doneDatesKey = "daisy.actionItemDoneDates"   // [String: Date]

    /// Persisted per-item completion date; presence = done. Replaces the
    /// old bool map so the card can distinguish "done today" (keep struck
    /// at the bottom) from "done earlier" (gone).
    @ObservationIgnored
    private var doneDates: [String: Date]

    private init() {
        if let dates = UserDefaults.standard.dictionary(forKey: Self.doneDatesKey) as? [String: Date] {
            doneDates = dates
        } else if let legacy = UserDefaults.standard.dictionary(forKey: Self.stateKey) as? [String: Bool] {
            // One-time migration: keep done-ness, but stamp distantPast —
            // we don't know when they were done, and "before today" means
            // they won't resurface in today's Done group.
            doneDates = legacy.compactMapValues { $0 ? Date.distantPast : nil }
            UserDefaults.standard.set(doneDates, forKey: Self.doneDatesKey)
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
        } else {
            doneDates = [:]
        }
    }

    var openItems: [TrackedActionItem] { items.filter { $0.doneAt == nil } }
    var openCount: Int { openItems.count }

    /// Items completed TODAY — the card shows these struck-through at the
    /// bottom until the day rolls over, then they drop out on their own
    /// (the source item stays `done`, just no longer "done today").
    var doneTodayItems: [TrackedActionItem] {
        let cal = Calendar.current
        return items
            .filter { $0.doneAt.map { cal.isDateInToday($0) } ?? false }
            .sorted { ($0.doneAt ?? .distantPast) < ($1.doneAt ?? .distantPast) }
    }

    /// Rebuild from the session corpus (call after SessionStore.refresh).
    /// Also prunes persisted states for items that no longer exist so the
    /// defaults blob can't grow forever.
    func rebuild(from sessions: [StoredSession]) {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.windowDays, to: Date()
        ) ?? .distantPast

        var rebuilt: [TrackedActionItem] = []
        for session in sessions where session.startedAt >= cutoff {
            guard let summary = session.summary else { continue }
            for (idx, text) in summary.actionItems.enumerated() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let id = "\(session.id)#\(idx)"
                rebuilt.append(TrackedActionItem(
                    id: id,
                    text: trimmed,
                    sessionID: session.id,
                    sessionTitle: session.title,
                    sessionDate: session.startedAt,
                    doneAt: doneDates[id]
                ))
            }
        }
        rebuilt.sort { $0.sessionDate > $1.sessionDate }
        items = rebuilt

        // Keep the defaults blob bounded WITHOUT ever reading "absent from
        // this rebuild" as "gone forever": a stamp survives while its item
        // is live, and otherwise until it ages out. An empty or half-loaded
        // corpus therefore prunes nothing — see `stateRetentionDays`.
        guard !sessions.isEmpty else { return }
        let liveIDs = Set(rebuilt.map(\.id))
        let horizon = Calendar.current.date(
            byAdding: .day, value: -Self.stateRetentionDays, to: Date()
        ) ?? .distantPast
        let pruned = doneDates.filter { liveIDs.contains($0.key) || $0.value >= horizon }
        if pruned.count != doneDates.count {
            doneDates = pruned
            persist()
        }
    }

    func setDone(_ item: TrackedActionItem, done: Bool) {
        let stamp: Date? = done ? Date() : nil
        if let stamp { doneDates[item.id] = stamp } else { doneDates.removeValue(forKey: item.id) }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].doneAt = stamp
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(doneDates, forKey: Self.doneDatesKey)
    }
}
