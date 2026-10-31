//
//  MorningBrief.swift
//  Daisy
//
//  The morning brief: once per day, assemble today's calendar + the open
//  action items (ActionItemStore) and — when a provider is available —
//  an LLM "what matters today" lede with 2-4 Focus priorities. The
//  checkable open-items list on the card is the source of truth; the LLM
//  layer is narrative on top, and the card degrades gracefully to plain
//  meetings + checkboxes when no provider can run.
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
        /// LLM lede + focus priorities are ready.
        case ready(MeetingSummary)
        /// Cloud provider selected — waiting for an explicit tap.
        case needsConsent(String)
        /// Provider can't run / failed — card shows without the lede.
        case unavailable
    }

    private(set) var ledeState: LedeState = .idle

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MorningBrief")
    private static let generatedDayKeyKey = "daisy.morningBrief.generatedDay"
    private static let cachedSummaryKey = "daisy.morningBrief.cachedSummary"
    private static let cloudConsentKey = "daisy.morningBrief.cloudConsented"

    private init() {}

    /// Once the user has generated a cloud-provider brief even once, treat
    /// it as standing consent and auto-generate on later days — no daily
    /// "Generate" tap. (Local providers never gate at all.) The first
    /// cloud brief still needs one explicit tap, which sets this.
    private var cloudBriefConsented: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cloudConsentKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cloudConsentKey) }
    }

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
        guard settings.morningBriefEnabled else { return }

        ActionItemStore.shared.rebuild(from: SessionStore.shared.sessions)

        let scope = Self.briefScope()
        // Cache key carries WHICH day the lede is about, not just the
        // date: when the agenda rolls over to tomorrow in the evening,
        // the morning's lede must not be reused for it.
        let today = UsageStats.dayKey(for: Date()) + (scope.isTomorrow ? "-tomorrow" : "-today")
        // Already have this day's lede in memory — nothing to do.
        if !force, generatedDayKey == today, case .ready = ledeState { return }
        // Relaunched the same day: restore the persisted lede instead of
        // re-running the LLM (local) or re-prompting for consent (cloud).
        if !force, generatedDayKey == today, let cached = cachedSummary {
            ledeState = .ready(cached)
            return
        }
        if case .generating = ledeState { return }

        let events = scope.events
        let openItems = ActionItemStore.shared.openItems
        // Nothing to brief about — the card renders its own empty state;
        // don't spend an LLM call narrating an empty day.
        guard !events.isEmpty || !openItems.isEmpty else {
            ledeState = .unavailable
            return
        }

        // Effective-local (configured endpoint, not provider kind) —
        // remote-pointed MCP/Ollama must not auto-run. See Summarizer.
        let providerLocal = Summarizer.shared.providerIsEffectivelyLocal
        if !providerLocal && !force && !cloudBriefConsented {
            ledeState = .needsConsent(Summarizer.shared.providerKind.shortName)
            return
        }
        guard Summarizer.shared.availability == .available else {
            ledeState = .unavailable
            return
        }

        ledeState = .generating
        let dossier = Self.buildDossier(
            events: events, openItems: openItems, isTomorrow: scope.isTomorrow
        )
        do {
            let summary = try await Summarizer.shared.runProbe(
                transcript: dossier,
                title: "Morning brief",
                localeHint: nil,
                task: .morningBrief
            )
            ledeState = .ready(summary)
            generatedDayKey = today
            cachedSummary = summary
            // First successful cloud brief = standing consent for later days.
            if !providerLocal { cloudBriefConsented = true }
            log.info("Morning brief lede ready (\(events.count) meetings, \(openItems.count) open items)")
        } catch {
            ledeState = .unavailable
            log.error("Morning brief lede failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Explicit tap — consent for a cloud provider / manual refresh.
    func regenerate(settings: AppSettings) async {
        generatedDayKey = nil
        cachedSummary = nil
        ledeState = .idle
        await prepare(settings: settings, force: true)
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
