// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MorningBrief.swift
//  Daisy
//
//  The morning brief: once per day, assemble today's calendar + the open
//  action items (ActionItemStore) and — when a provider can write one —
//  an LLM "what matters today" lede. The checkable open-items list on the
//  card is the source of truth; the LLM layer is narrative on top, and the
//  card degrades gracefully to plain meetings + checkboxes without it.
//
//  No lede without open items, on any provider (daisy-app#12): the prompt
//  asks for what is open, and with nothing open a model made it up — people,
//  overdue reports. The meetings are on the card either way, and the
//  calendar then goes to nobody. And none from Apple Intelligence
//  (`SummaryProviderKind.writesDayLede`).
//
//  Privacy contract mirrors the pre-meeting brief: a LOCAL summary
//  provider auto-generates; a CLOUD provider waits for an explicit
//  "Generate" tap (.needsConsent). Everything else is on-device.
//
//  Also owns the optional daily notification (a repeating local
//  UNCalendarNotificationTrigger at the user's chosen time). The
//  notification body is deliberately generic — counts aren't known at
//  schedule time and transcript content never belongs in a banner.
//

import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications
import os

@MainActor
@Observable
final class MorningBriefStore {
    static let shared = MorningBriefStore()

    enum LedeState: Equatable {
        case idle
        case generating
        /// The LLM lede is ready.
        case ready(MeetingSummary)
        /// Cloud provider selected — waiting for an explicit tap.
        case needsConsent(String)
        /// Provider can't run / failed — card shows without the lede.
        case unavailable
    }

    private(set) var ledeState: LedeState = .idle

    /// The request a lede is being written by, if any.
    @ObservationIgnored
    private let requests = DayLedeRequests()

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MorningBrief")
    private static let generatedDayKeyKey = "daisy.morningBrief.generatedDay"
    private static let cachedSummaryKey = "daisy.morningBrief.cachedSummary"

    private init() {}

    /// Day key the current lede was generated for (persisted so an app
    /// relaunch the same morning doesn't spend a second LLM call).
    private var generatedDayKey: String? {
        get { UserDefaults.standard.string(forKey: Self.generatedDayKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.generatedDayKeyKey) }
    }

    /// The lede generated for `generatedDayKey`, PERSISTED so relaunching
    /// the same day restores it instead of re-running the LLM (local) or —
    /// worse — dropping back to `.needsConsent` and forcing a second
    /// "Generate" tap (cloud). Before this the day-key was saved but the
    /// summary itself lived only in memory, so every relaunch looked
    /// ungenerated. Cleared on regenerate; a new day's key sidesteps it.
    private var cachedSummary: MeetingSummary? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.cachedSummaryKey) else { return nil }
            return try? JSONDecoder().decode(MeetingSummary.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.cachedSummaryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.cachedSummaryKey)
            }
        }
    }

    /// Idempotent daily prepare — call from the card's `.task`. Rebuilds
    /// the open-items list, then generates the lede once per local day
    /// (local provider) or parks at `.needsConsent` (cloud provider).
    func prepare(settings: AppSettings, force: Bool = false) async {
        guard settings.morningBriefEnabled else {
            stop()
            return
        }

        ActionItemStore.shared.rebuild(from: SessionStore.shared.sessions)

        let scope = Self.briefScope()
        let events = scope.events
        // The brief's lede goes to the summary provider: a voice note's
        // steps only as the note itself could go there (07.11). The card
        // still shows every open step — it reads the store, not this.
        let openItems = Self.itemsForProvider(ActionItemStore.shared.openItems, gate: .current)
        // First, before anything kept from earlier: with everything closed
        // since, or on Apple Intelligence, the lede on screen goes too. The
        // stored one stays — on a cold launch the items may not be loaded.
        let provider = Summarizer.shared.providerKind
        guard Self.hasLede(openItems: openItems, provider: provider) else {
            requests.cancel()
            ledeState = .unavailable
            return
        }
        // Cache key carries WHICH day the lede is about, not just the
        // date: when the agenda rolls over to tomorrow in the evening,
        // the morning's lede must not be reused for it. `-2`: a lede stored
        // by 1.0.8.55 or earlier may name people who don't exist.
        let today = UsageStats.dayKey(for: Date()) + (scope.isTomorrow ? "-tomorrow" : "-today") + "-2"
        // Effective-local (configured endpoint, not provider kind) —
        // remote-pointed MCP/Ollama must not auto-run. See Summarizer.
        let providerLocal = Summarizer.shared.providerIsEffectivelyLocal
        let destination = Summarizer.shared.voiceNoteDestination
        let request = DayLedeRequests.Key(
            day: today, destination: destination,
            dossier: Self.buildDossier(events: events, openItems: openItems, isTomorrow: scope.isTomorrow)
        )
        if force {
            generatedDayKey = nil
            cachedSummary = nil
        } else if requests.key == request {
            // Being written from the same calendar and items.
            return
        }
        // Asked for by the person a moment ago, over a calendar or items
        // that changed since: their tap covers the new one too, to the same
        // place.
        let asked = requests.key?.destination == destination
        requests.cancel()
        // Already have this day's lede in memory — nothing to do.
        if !force, generatedDayKey == today, case .ready = ledeState { return }
        // Relaunched the same day: restore the persisted lede instead of
        // re-running the LLM (local) or re-prompting for consent (cloud).
        if !force, generatedDayKey == today, let cached = cachedSummary {
            ledeState = .ready(cached)
            return
        }

        let consent = Self.consent()
        if !providerLocal && !force && !asked && !consent.allows(destination) {
            ledeState = .needsConsent(provider.shortName)
            return
        }
        guard Summarizer.shared.availability == .available else {
            ledeState = .unavailable
            return
        }

        ledeState = .generating
        let result = await requests.run(key: request) {
            // Where all of the above was checked for.
            guard Summarizer.shared.voiceNoteDestination == destination else { throw CancellationError() }
            return try await Summarizer.shared.runProbe(
                transcript: request.dossier,
                title: "Morning brief",
                localeHint: nil,
                task: .morningBrief
            )
        }
        switch result {
        case nil:
            // Dropped: whoever dropped it has set the state.
            return
        case .success(let summary):
            ledeState = .ready(summary)
            generatedDayKey = today
            cachedSummary = summary
            // First successful cloud brief = standing consent for later days.
            if !providerLocal { consent.allow(destination) }
            log.info("Morning brief lede ready (\(events.count) meetings, \(openItems.count) open items)")
        case .failure(let error):
            ledeState = .unavailable
            log.error("Morning brief lede failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// At launch, before the provider can be changed: the old yes goes to
    /// the one it has been used with (`DayLedeConsent`).
    static func migrateConsent() {
        guard !TestHost.isActive else { return }
        _ = consent()
    }

    private static func consent() -> DayLedeConsent {
        let summarizer = Summarizer.shared
        return DayLedeConsent(
            currentDestination: summarizer.providerIsEffectivelyLocal ? nil : summarizer.voiceNoteDestination)
    }

    /// Whether the card has an intro written by a model: something is open,
    /// and the provider writes one.
    static func hasLede(openItems: [TrackedActionItem], provider: SummaryProviderKind) -> Bool {
        !openItems.isEmpty && provider.writesDayLede
    }

    /// The open steps the lede's request may carry to the provider the
    /// gate describes: every meeting's; a voice note's only when the
    /// voice-note gate would let the note go there (`VoiceNoteProfile.mayFeed`).
    static func itemsForProvider(_ items: [TrackedActionItem], gate: VoiceNoteProfile.Gate) -> [TrackedActionItem] {
        items.filter { VoiceNoteProfile.mayFeed(isVoiceNote: $0.fromVoiceNote, kindKnown: $0.kindKnown, recordedAt: $0.sessionDate, gate: gate) }
    }

    /// Explicit tap — consent for a cloud provider / manual refresh.
    func regenerate(settings: AppSettings) async {
        await prepare(settings: settings, force: true)
    }

    /// The brief was turned off: nothing it asked for goes on.
    func stop() {
        requests.cancel()
        ledeState = .idle
    }

    // MARK: - Sources

    /// Today's still-relevant events (same calendar-day rule as Home).
    static func todaysEvents() -> [DaisyMeeting] {
        let cal = Calendar.current
        let now = Date()
        return CalendarService.shared.upcomingEvents.filter { event in
            cal.isDate(event.startDate, inSameDayAs: now) && event.endDate > now
        }
    }

    /// Tomorrow's whole calendar day (needs the 48 h lookahead in
    /// ServiceWiring to be populated).
    static func tomorrowsEvents() -> [DaisyMeeting] {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) else { return [] }
        return CalendarService.shared.upcomingEvents.filter {
            cal.isDate($0.startDate, inSameDayAs: tomorrow)
        }
    }

    /// THE day the card is about — single source of truth shared by the
    /// lede and the agenda below it (Egor, 2026-07-26).
    ///
    /// The bug this fixes: the agenda rolled over to tomorrow once
    /// today's meetings were done, but the lede was generated from
    /// `todaysEvents()` and cached under a plain day key — so in the
    /// evening the card read "TOMORROW", listed tomorrow's meetings,
    /// and narrated this morning. Two different days in one card.
    static func briefScope() -> (events: [DaisyMeeting], isTomorrow: Bool) {
        let today = todaysEvents()
        if !today.isEmpty { return (today, false) }
        let tomorrow = tomorrowsEvents()
        return tomorrow.isEmpty ? (today, false) : (tomorrow, true)
    }

    nonisolated static func buildDossier(
        events: [DaisyMeeting],
        openItems: [TrackedActionItem],
        isTomorrow: Bool = false
    ) -> String {
        // Which day the dossier describes — the model must not narrate
        // "today" over tomorrow's agenda (2026-07-26).
        var out = isTomorrow
            ? "TOMORROW'S CALENDAR (today is over — brief the user on the DAY AHEAD, in the future tense):\n"
            : "TODAY'S CALENDAR:\n"
        if events.isEmpty {
            out += "(no meetings scheduled)\n"
        } else {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            for e in events {
                out += "- \(tf.string(from: e.startDate)) \(e.title)"
                if !e.attendees.isEmpty {
                    out += " (with \(e.attendees.prefix(4).joined(separator: ", ")))"
                }
                out += "\n"
            }
        }

        out += "\nOPEN ACTION ITEMS (from the user's recent meetings):\n"
        if openItems.isEmpty {
            out += "(none)\n"
        } else {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            // Bound the dossier: 40 items is far beyond a sane open list.
            for item in openItems.prefix(40) {
                out += "- [\(df.string(from: item.sessionDate)) · \(item.sessionTitle)] \(item.text)\n"
            }
        }
        return out
    }

    // MARK: - Daily nudge (widget bubble)

    private static let notificationID = "daisy.morningBrief.daily"

    /// The in-app timer that fires the daily bubble. One-shot,
    /// re-armed after each fire; `Timer(fire:)` delivers late-but-once
    /// after a sleep that spans the fire time, which is exactly the
    /// "first thing after opening the lid" moment the brief is for.
    @ObservationIgnored
    private var briefNudgeTimer: Timer?

    /// (Re)arm the daily nudge per settings. Call on launch and
    /// whenever the toggle/time changes. Since 2026-08-21 this is an
    /// IN-APP timer driving a widget bubble, not a scheduled system
    /// banner — Daisy is a resident menu-bar app, so the process is
    /// alive at brief time and the OS scheduler bought us nothing but
    /// a notification-permission dependency. Name kept so the three
    /// Settings/Home call sites didn't have to move.
    static func rescheduleNotification(settings: AppSettings) {
        // Retire any banner scheduled by a previous build outright.
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID])
        shared.briefNudgeTimer?.invalidate()
        shared.briefNudgeTimer = nil
        guard settings.morningBriefEnabled, settings.morningBriefNotifyEnabled else { return }
        shared.armBriefNudge(minutes: settings.morningBriefNotifyMinutes)
    }

    private func armBriefNudge(minutes: Int) {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        guard let todayFire = Calendar.current.date(from: comps) else { return }
        let fire = todayFire > Date()
            ? todayFire
            : Calendar.current.date(byAdding: .day, value: 1, to: todayFire) ?? todayFire.addingTimeInterval(86_400)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentBriefNudge()
                // Re-arm for tomorrow. Same minutes is correct: any
                // Settings change re-runs rescheduleNotification and
                // replaces this timer wholesale.
                self.armBriefNudge(minutes: minutes)
            }
        }
        timer.tolerance = 60  // morning — a minute either way is fine
        RunLoop.main.add(timer, forMode: .common)
        briefNudgeTimer = timer
        log.info("Morning-brief nudge armed for \(fire.description, privacy: .public)")
    }

    /// The nudge itself: an informational pill whose action (and
    /// whole-pill tap) opens Daisy on Home, where the card lives.
    /// Generic wording on purpose — the pill's job is to bring the
    /// user to the card, not leak its contents.
    private func presentBriefNudge() {
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(
                text: String(localized: "Your morning brief is ready"),
                actionTitle: String(localized: "Open"),
                actionSymbol: "sun.horizon",
                tag: "morning-brief",
                action: {
                    AppNavigation.shared.section = .home
                    if let open = WidgetBubbleCenter.shared.openMainWindow {
                        open()
                    } else {
                        // Best-effort AppKit fallback: can surface an
                        // existing window but cannot recreate a closed
                        // scene (that needs SwiftUI's openWindow).
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        AppNavigation.mainWindow?.makeKeyAndOrderFront(nil)
                    }
                }
            ),
            notificationTitle: String(localized: "Your morning brief is ready"),
            notificationBody: String(localized: "Today's meetings and your open items are waiting in Daisy.")
        )
    }
}

/// Where the lede may go without a tap. Once the person has generated a
/// brief with a cloud provider, later days' run by themselves — with that
/// provider, not with whichever is picked next: up to 1.0.8.55 one yes
/// covered them all.
struct DayLedeConsent {
    private static let key = "daisy.morningBrief.cloudConsentedDestinations"
    private static let oldKey = "daisy.morningBrief.cloudConsented"
    private let defaults: UserDefaults

    /// - Parameter currentDestination: where a lede goes now, nil when it
    ///   stays on this Mac. The first time, the old yes, which named
    ///   nobody, becomes a yes to it; with none it is asked for again. The
    ///   old one is left as it was, for an earlier build.
    init(currentDestination: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard defaults.object(forKey: Self.key) == nil else { return }
        let old = defaults.bool(forKey: Self.oldKey) ? currentDestination : nil
        defaults.set(old.map { [$0] } ?? [], forKey: Self.key)
    }

    func allows(_ destination: String) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(destination)
    }

    func allow(_ destination: String) {
        guard !allows(destination) else { return }
        defaults.set((defaults.stringArray(forKey: Self.key) ?? []) + [destination], forKey: Self.key)
    }
}

/// One lede request at a time, in a task of its own: the card's
/// `.task(id:)` cancels its `prepare` whenever the agenda changes, and a
/// request cancelled along with it left the card with no intro. A newer
/// request, or `cancel()`, drops the one in flight.
@MainActor
final class DayLedeRequests {
    /// What a request is about. One made from a calendar or items that
    /// changed since, or for another provider, is another request.
    struct Key: Equatable {
        let day: String
        /// `Summarizer.voiceNoteDestination`: the provider and its endpoint.
        let destination: String
        let dossier: String
    }

    /// The request in flight, nil when there is none.
    private(set) var key: Key?
    private var task: Task<MeetingSummary, Error>?
    private var current = 0

    func cancel() {
        current += 1
        key = nil
        task?.cancel()
        task = nil
    }

    /// The answer, or nil when the request was dropped on the way — also
    /// when its answer came anyway.
    func run(
        key: Key, _ request: @escaping @MainActor () async throws -> MeetingSummary
    ) async -> Result<MeetingSummary, Error>? {
        cancel()
        let mine = current
        self.key = key
        let task = Task {
            try Task.checkCancellation()
            return try await request()
        }
        self.task = task
        let result = await task.result
        guard mine == current else { return nil }
        self.key = nil
        self.task = nil
        return result
    }
}
