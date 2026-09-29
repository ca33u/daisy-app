//
//  CalendarService.swift
//  Daisy
//
//  EventKit-backed calendar awareness. Reads the next 24h of events,
//  surfaces "is this a meeting?" by detecting Zoom / Google Meet /
//  Teams / Webex / Whereby / Jitsi URLs in event.location / .url /
//  .notes, and emits a callback when one starts so RecordingSession
//  can auto-record.
//
//  Plays nicely with `MeetingDetector` (NSWorkspace-based, watches
//  Zoom.app / Teams.app launches). The two surfaces overlap for
//  native-app meetings; CalendarService is the only path for
//  browser-based meetings (Google Meet in Chrome, where the
//  bundle id is just "com.google.Chrome").
//
//  ─── Architecture ────────────────────────────────────────────────
//
//  The `EKEventStore` is a singleton — losing the store invalidates
//  every `EKEvent` reference we've handed out (they're lazy proxies
//  to a Core Data row inside the store). For this reason
//  `CalendarService` ONLY returns immutable `DaisyMeeting` value
//  types outside its own boundary.
//
//  ─── Permission flow (macOS 14+) ─────────────────────────────────
//
//  Apple split calendar access into `.writeOnly` and `.fullAccess`
//  on macOS 14 (Sonoma). Daisy needs `.fullAccess` — we read events,
//  we never write. Info.plist must contain
//  `NSCalendarsFullAccessUsageDescription` (with
//  `NSCalendarsUsageDescription` as legacy fallback). No sandbox
//  entitlement key is required for AppKit / SwiftUI apps — TCC is
//  driven entirely by the Info.plist strings.
//

import AppKit
import EventKit
import Foundation
import Observation
import os
import SwiftUI

// MARK: - DTO

/// Immutable snapshot of an EKEvent. Crossing the CalendarService
/// boundary as EKEvent is unsafe (EKEvent is a proxy into the
/// store's Core Data) so we always project to this struct.
struct DaisyMeeting: Identifiable, Hashable, Sendable {
    /// External (provider-side) identifier — survives local re-sync,
    /// matches across devices via iCloud. Preferred for long-term
    /// transcript-to-meeting binding.
    let externalID: String?
    /// Local EKEvent identifier — only stable within this Mac's
    /// EventKit store. Use as fallback.
    let localID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    /// The first detected meeting URL (Zoom / Meet / Teams / etc.).
    /// `nil` means this event is not a recordable meeting.
    let meetingURL: URL?
    /// Provider slug ("zoom", "meet", "teams", "webex", "whereby",
    /// "jitsi") — for UI badges.
    let meetingPlatform: String?
    /// Calendar colour for UI dot.
    let calendarColorHex: String?
    /// Display names of invitees (excluding the organizer when
    /// possible). Powers the "Speaker A → Alex" mapping UI in
    /// SessionDetailView. Empty list if the calendar event had no
    /// attendees attached, or only had email addresses without
    /// display names.
    let attendees: [String]
    /// Raw email addresses of invitees (best-effort — EventKit
    /// returns `mailto:...` URLs and CalDAV-synced Google events
    /// often have only emails). Used by the 1.0.5 client-tagging
    /// auto-suggestion to identify the dominant external domain on
    /// the call. Order matches `attendees` where possible; entries
    /// can be empty strings if the participant URL wasn't a mailto.
    let attendeeEmails: [String]

    var id: String { localID }
    var isMeeting: Bool { meetingURL != nil }
}

// MARK: - Service

@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    /// Cached, filtered upcoming meetings — only events with a
    /// detected meeting URL. UI binds directly to this.
    var upcomingMeetings: [DaisyMeeting] = []

    /// Cached upcoming events (with or without a meeting URL) for any
    /// UI that wants to show the full calendar, not just meetings.
    var upcomingEvents: [DaisyMeeting] = []

    /// Last permission state from EventKit. Trips UI between
    /// "Connect Calendar" CTA and the events list.
    var authorizationStatus: EKAuthorizationStatus =
        EKEventStore.authorizationStatus(for: .event)

    // ─── Internals ──────────────────────────────────────────────────

    private let store = EKEventStore()
    private var storeChangeObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var firedEventIDs: Set<String> = []
    /// Events with a precise one-shot start timer armed but not yet
    /// fired. Prevents a poll tick from arming the same event twice.
    private var scheduledEventIDs: Set<String> = []
    /// Live one-shot start timers keyed by event localID, so they can
    /// be invalidated on stop()/disable.
    private var fireTimers: [String: Timer] = [:]

    private var onMeetingStart: ((DaisyMeeting) -> Void)?
    private var lookaheadHours: Int = 24
    private var autoStartEnabled: Bool = false

    private init() {}

    // MARK: - Permission

    /// Ask the user for full calendar access. Returns the resulting
    /// status. Safe to call multiple times — EventKit no-ops if the
    /// state is already determined.
    @discardableResult
    func requestAccess() async -> EKAuthorizationStatus {
        let preStatus = EKEventStore.authorizationStatus(for: .event)
        Self.permLog.info("requestAccess: pre-call status=\(Self.describe(preStatus), privacy: .public)")

        // ─── Foreground the app + ensure a key window exists ──────────
        //
        // macOS TCC silently refuses to show the privacy prompt when
        // the requesting app has no key window in foreground state.
        // Clicking "Connect Apple Calendar" from a MenuBarExtra popover
        // — which is what Daisy's menu-bar UI is — would otherwise hit
        // exactly that wall: requestFullAccessToEvents returns false
        // immediately, no dialog appears, status stays .notDetermined,
        // and the user has no way to grant access.
        //
        // Activating NSApp + raising a titled window promotes Daisy
        // into a regular foreground app for the duration of the
        // request, which is the state TCC requires.
        Self.bringAppToForegroundForPrompt()

        // IMPORTANT: use the LONG-LIVED singleton `store`, NOT a fresh
        // instance. On macOS 14+ creating multiple EKEventStore() in
        // the same process causes calaccessd to refuse the second
        // connection ("Client tried to open too many connections to
        // calaccessd. Refusing to open another.") — and that refusal
        // surfaces as exactly the symptom we were seeing: granted=false
        // returned synchronously, no throw, no prompt, status unchanged.
        // See Apple Developer Forums thread 737536.
        do {
            let granted = try await store.requestFullAccessToEvents()
            Self.permLog.info("requestAccess: requestFullAccessToEvents returned granted=\(granted, privacy: .public)")
        } catch {
            // Denied or system error — log loudly so we can tell apart
            // "user denied" from "TCC daemon refused the request".
            Self.permLog.error("requestAccess: requestFullAccessToEvents threw: \(error.localizedDescription, privacy: .public) [\(String(describing: error), privacy: .public)]")
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        Self.permLog.info("requestAccess: post-call status=\(Self.describe(status), privacy: .public)")
        authorizationStatus = status
        return status
    }

    /// Promote Daisy into foreground regular-app state so the TCC
    /// prompt has a key window to anchor against. Idempotent.
    private static func bringAppToForegroundForPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.isHidden { NSApp.unhide(nil) }

        // ─── Diagnostic dump ──────────────────────────────────────────
        // Tahoe 26.2 + SwiftUI Window scenes have shown weird
        // behaviours where the supposedly-titled main window isn't
        // present in NSApp.windows at all. Log every window so we can
        // see what's actually in the runloop's window list before
        // filtering.
        let allWindows = NSApp.windows
        permLog.info("NSApp.windows count=\(allWindows.count, privacy: .public)")
        for (idx, w) in allWindows.enumerated() {
            let cls = String(describing: type(of: w))
            let title = w.title
            let ident = w.identifier?.rawValue ?? "nil"
            let visible = w.isVisible
            let canKey = w.canBecomeKey
            let isKey = w.isKeyWindow
            let isMain = w.isMainWindow
            let titled = w.styleMask.contains(.titled)
            // 2026-05-27 — title flipped to `.private`. Today window
            // titles are "Daisy" or empty; safe. Tomorrow if a per-
            // session window adds the meeting title to chrome (which
            // is PII), this log would silently leak it into the unified
            // log. Preventive downgrade.
            permLog.info("  window[\(idx, privacy: .public)] class=\(cls, privacy: .public) title='\(title, privacy: .private)' ident=\(ident, privacy: .public) visible=\(visible, privacy: .public) canBecomeKey=\(canKey, privacy: .public) isKey=\(isKey, privacy: .public) isMain=\(isMain, privacy: .public) titled=\(titled, privacy: .public)")
        }

        // ─── Try to key any plausible main window ─────────────────────
        // Relaxed filter: any visible, key-eligible NSWindow that
        // isn't an obvious accessory (no title AND not titled = panel).
        // The main window might come up as titled with title 'Daisy',
        // titled with empty title (SwiftUI quirk), or just a regular
        // NSWindow with canBecomeKey=true.
        let candidate = allWindows.first(where: { window in
            window.isVisible && window.canBecomeKey
        })

        if let candidate {
            candidate.makeKeyAndOrderFront(nil)
            permLog.info("bringAppToForegroundForPrompt: keyed window class=\(String(describing: type(of: candidate)), privacy: .public) title='\(candidate.title, privacy: .private)'")
        } else {
            permLog.error("bringAppToForegroundForPrompt: NO key-eligible visible window found — calendar prompt cannot anchor")
        }
    }

    /// Dedicated logger for Calendar permission flow — separate
    /// category so it's easy to filter in Console.app:
    ///   `subsystem:app.essazanov.Daisy category:Calendar/Perm`
    private static let permLog = Logger(subsystem: "app.essazanov.Daisy", category: "Calendar/Perm")

    /// Pretty-printer for `EKAuthorizationStatus` — the raw integer is
    /// useless in Console; this gives "notDetermined / denied /
    /// restricted / writeOnly / fullAccess" instead.
    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .fullAccess:    return "fullAccess"
        case .writeOnly:     return "writeOnly"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    /// Always opens System Settings → Privacy → Calendars.
    /// Used by both "Revoke…" (when access is granted — sends the
    /// user to the panel where they can flip Daisy off) AND the
    /// re-grant flow after a denial.
    func openCalendarPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }


    // MARK: - Fetch + observe

    /// Begin maintaining the `upcomingMeetings` / `upcomingEvents`
    /// caches. Idempotent — calling again replaces the previous
    /// configuration (handy when the user changes auto-start prefs).
    func start(
        lookaheadHours: Int = 24,
        autoStartOnMeeting: Bool,
        onMeetingStart: @escaping (DaisyMeeting) -> Void
    ) {
        self.lookaheadHours = lookaheadHours
        self.autoStartEnabled = autoStartOnMeeting
        self.onMeetingStart = onMeetingStart

        // Subscribe to EventKit change notifications (covers calendar
        // sync, user-edits in Calendar.app, iCloud reconcile, etc.).
        if storeChangeObserver == nil {
            storeChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [weak self] _ in
                // The notification handler is @Sendable in Swift 6.
                // Re-capture weak self inside the Task so we don't
                // strongly retain the service across the actor hop.
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }

        // Start the rolling poll — one timer for all events, 15s
        // tick. Lighter than per-event NSTimer.
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }

        refresh()
    }

    /// Stop observing and clear caches. Called when the user revokes
    /// the auto-start preference or when the app is shutting down.
    func stop() {
        if let observer = storeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            storeChangeObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        for t in fireTimers.values { t.invalidate() }
        fireTimers.removeAll()
        scheduledEventIDs.removeAll()
        onMeetingStart = nil
        upcomingMeetings = []
        upcomingEvents = []
        firedEventIDs = []
    }

    /// Force a re-fetch of the events window. Pulls from BOTH
    /// EventKit (Apple Calendar / Internet Accounts-synced Google /
    /// Outlook / iCloud) AND Google Calendar API (direct OAuth,
    /// for users who don't have Google in macOS Internet Accounts).
    /// Results are merged + deduped — same event appearing in both
    /// sources is counted once.
    ///
    /// EventKit is sync (local cache). Google is an async HTTPS
    /// round-trip — we kick it off in a Task and update
    /// `upcomingEvents` again when it completes, so the UI doesn't
    /// block on network for the EventKit portion.
    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status

        // 1. EventKit synchronous fetch (always — even when
        //    permission denied we want to clear the cache + still
        //    try Google).
        var projected: [DaisyMeeting] = []
        if status == .fullAccess {
            let now = Date()
            let end = now.addingTimeInterval(TimeInterval(lookaheadHours * 3600))
            let calendars = store.calendars(for: .event)
            let predicate = store.predicateForEvents(
                withStart: now,
                end: end,
                calendars: calendars
            )
            let events = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
            projected = events.compactMap(DaisyMeeting.init(ekEvent:))
        }

        // Publish EventKit portion immediately so UI updates while
        // Google fetch is in flight.
        upcomingEvents = projected
        upcomingMeetings = projected.filter(\.isMeeting)
        let visibleIDs = Set(projected.map(\.localID))
        firedEventIDs = firedEventIDs.intersection(visibleIDs)

        // 2. Google async fetch — merge when complete.
        if GoogleAccountStore.shared.isConnected {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let googleEvents = try await GoogleCalendarService.shared
                        .fetchUpcomingEvents(lookaheadHours: self.lookaheadHours)
                    self.mergeGoogleEvents(googleEvents, into: projected)
                } catch {
                    // Log but don't surface — EventKit results are
                    // already visible, Google failure is silent
                    // degradation. UI can read GoogleAccountStore
                    // state directly for a connected-but-failing badge.
                    self.googleFetchLog.warning("Google fetch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Folder pattern: keep a logger reference for the Google
    /// branch so error messages get the right category in Console.
    private let googleFetchLog = Logger(subsystem: "app.essazanov.Daisy", category: "Calendar/Google")

    /// Merge Google events into the published `upcomingEvents`
    /// array, deduping against the EventKit baseline. Two-pass
    /// dedup:
    ///   - first by `externalID` (Google's iCalUID often matches
    ///     EventKit's calendarItemExternalIdentifier for the same
    ///     event synced via both paths)
    ///   - then by (startDate ± 30s + title-prefix match) — best
    ///     effort fuzzy match for events that don't share an ID
    ///     across providers
    private func mergeGoogleEvents(_ google: [DaisyMeeting], into eventKit: [DaisyMeeting]) {
        // Build dedup sets from the EventKit baseline.
        let knownExternalIDs = Set(eventKit.compactMap(\.externalID))

        // Coarse-grained time bucket: "same event" if start time
        // within 30s AND title prefix matches (first 12 chars).
        // Sufficient for the common case where Google account
        // is in BOTH Internet Accounts (EventKit sees) and
        // connected via OAuth (we see directly).
        struct FuzzyKey: Hashable {
            let bucketStart: Int  // floor(startDate / 30s)
            let titlePrefix: String
        }
        let knownFuzzy = Set(eventKit.map { ek -> FuzzyKey in
            FuzzyKey(
                bucketStart: Int(ek.startDate.timeIntervalSince1970 / 30),
                titlePrefix: String(ek.title.prefix(12)).lowercased()
            )
        })

        let unique = google.filter { gevent in
            // First-pass dedup: explicit external ID match.
            if let ext = gevent.externalID, knownExternalIDs.contains(ext) {
                return false
            }
            // Second-pass dedup: time + title fuzzy match.
            let key = FuzzyKey(
                bucketStart: Int(gevent.startDate.timeIntervalSince1970 / 30),
                titlePrefix: String(gevent.title.prefix(12)).lowercased()
            )
            if knownFuzzy.contains(key) {
                return false
            }
            return true
        }

        // Combine + re-sort.
        let combined = (eventKit + unique).sorted { $0.startDate < $1.startDate }
        upcomingEvents = combined
        upcomingMeetings = combined.filter(\.isMeeting)
    }

    // MARK: - "Meeting starting now" tick

    /// Lead time before a meeting's scheduled start at which Daisy
    /// begins recording. Small and fixed so the recording reliably
    /// catches the opening words without a long pre-roll of dead air.
    private static let autoStartLeadSec: TimeInterval = 5
    /// How far ahead of the precise fire moment a poll tick will arm
    /// the one-shot timer. Must be ≥ the 15s poll interval so no
    /// meeting can slip between two consecutive ticks unarmed.
    private static let autoStartArmHorizonSec: TimeInterval = 20
    /// Don't auto-start a meeting whose scheduled start is already
    /// more than this far in the past (app launched/woke too late).
    private static let autoStartLateGraceSec: TimeInterval = 120

    /// Ticks between full `refresh()` calls — 20 × 15 s = every ~5 min.
    /// EventKit changes push via EKEventStoreChanged, but the Google
    /// OAuth path has no push channel: without this, Google events only
    /// updated at launch or via the (now removed) manual refresh button.
    private static let refreshEveryNTicks = 20
    private var ticksSinceRefresh = 0

    private func tick() {
        // Periodic re-fetch runs regardless of auto-start settings —
        // it's what keeps the Home "Today/Tomorrow" list current.
        ticksSinceRefresh += 1
        if ticksSinceRefresh >= Self.refreshEveryNTicks {
            ticksSinceRefresh = 0
            refresh()
        }

        guard autoStartEnabled, onMeetingStart != nil else { return }

        let now = Date()
        for meeting in upcomingMeetings {
            let id = meeting.localID
            guard !firedEventIDs.contains(id), !scheduledEventIDs.contains(id)
            else { continue }

            // Precise fire moment: a few seconds before the calendar
            // start, so the recording reliably catches the opening.
            let target = meeting.startDate
                .addingTimeInterval(-Self.autoStartLeadSec)
            let untilTarget = target.timeIntervalSince(now)

            if untilTarget <= 0 {
                // Target already reached → fire immediately as a
                // catch-up (app launched or woke mid-window), unless
                // we're absurdly late (>2 min past the scheduled
                // start), in which case suppress so a stale event
                // can't auto-record on a later tick.
                if meeting.startDate.timeIntervalSince(now)
                    >= -Self.autoStartLateGraceSec {
                    fireMeeting(meeting)
                } else {
                    firedEventIDs.insert(id)
                }
            } else if untilTarget <= Self.autoStartArmHorizonSec {
                // Arm a precise one-shot timer for the exact moment,
                // so the start lands at startDate − lead to the second
                // rather than being quantized to the 15s poll.
                scheduledEventIDs.insert(id)
                let timer = Timer(fire: target, interval: 0,
                                  repeats: false) { [weak self] t in
                    t.invalidate()
                    Task { @MainActor [weak self] in
                        self?.firePrescheduled(id)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                fireTimers[id] = timer
            }
            // else: too far out; a closer tick will arm it.
        }
    }

    /// Fire a meeting whose precise timer has elapsed. Re-validates
    /// against the live upcoming list — the event may have moved or
    /// been cancelled between arming and firing.
    private func firePrescheduled(_ id: String) {
        fireTimers[id] = nil
        scheduledEventIDs.remove(id)
        guard autoStartEnabled, !firedEventIDs.contains(id) else { return }
        guard let meeting = upcomingMeetings.first(where: { $0.localID == id })
        else { return }
        // If the event was pushed well into the future after arming,
        // don't fire now — a later tick will re-arm at the new time.
        if meeting.startDate.timeIntervalSinceNow
            > Self.autoStartArmHorizonSec { return }
        fireMeeting(meeting)
    }

    /// Common fire path: mark fired, drop any pending timer, invoke
    /// the auto-record callback.
    private func fireMeeting(_ meeting: DaisyMeeting) {
        let id = meeting.localID
        firedEventIDs.insert(id)
        scheduledEventIDs.remove(id)
        fireTimers[id]?.invalidate()
        fireTimers[id] = nil
        onMeetingStart?(meeting)
    }

    // MARK: - Hot-reconfigure (no need to stop/start)

    func setAutoStart(_ enabled: Bool) {
        autoStartEnabled = enabled
        guard !enabled else { return }
        // Disabling: tear down any armed start timers so a meeting
        // can't auto-record after the user turned auto-start off.
        for t in fireTimers.values { t.invalidate() }
        fireTimers.removeAll()
        scheduledEventIDs.removeAll()
    }

    // MARK: - Menu-bar label for next event

    /// Short rendering of the next upcoming event suitable for
    /// embedding in the macOS menu bar next to Daisy's icon
    /// (Granola-style "14:30 · Q3 Review"). Returns nil when:
    ///   • No events in the next 8 hours.
    ///   • No calendar source connected (EventKit denied AND no
    ///     Google OAuth) — the cache would be stale.
    /// Title truncated to 18 chars so the menu bar item stays
    /// compact even on a packed system menu bar.
    ///
    /// Source-agnostic: reads from `upcomingEvents` which the
    /// multiplexed `refresh()` populates from BOTH EventKit and
    /// direct Google API. A user with only Google connected (and
    /// Apple Calendar revoked) still sees their next meeting here.
    /// Shared look-ahead window for "upcoming" calendar entries. The
    /// menu-bar next-meeting label AND the popover meeting picker BOTH
    /// read it, so they can never disagree about what's upcoming — the
    /// bug where the menu bar named an event (8h window) that the picker
    /// then couldn't select (old 6h window).
    static let upcomingWindowSec: TimeInterval = 8 * 3600

    var nextMeetingShortLabel: String? {
        // Either Apple Calendar permission OR Google OAuth must be
        // live; otherwise `upcomingEvents` is empty/stale.
        let hasEventKit = (authorizationStatus == .fullAccess)
        let hasGoogle = GoogleAccountStore.shared.isConnected
        guard hasEventKit || hasGoogle else { return nil }

        let now = Date()
        let cutoff = now.addingTimeInterval(Self.upcomingWindowSec)
        guard let next = upcomingEvents.first(where: {
            $0.startDate > now && $0.startDate <= cutoff
        }) else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeStr = formatter.string(from: next.startDate)
        let title = next.title.trimmingCharacters(in: .whitespaces)
        let trimmed = title.count > 18 ? title.prefix(18) + "…" : title[...]
        return "\(timeStr) · \(trimmed)"
    }

    /// The menu-bar label as a countdown — «Q3 Review in 3h 5m» — instead
    /// of the clock time (Egor, 29.09: a countdown reads faster than a time
    /// you have to subtract from now). Same event selection and window as
    /// `nextMeetingShortLabel`; `now` is passed in so a TimelineView can
    /// re-render it every minute without touching the calendar.
    func nextMeetingCountdownLabel(now: Date = Date()) -> String? {
        let hasEventKit = (authorizationStatus == .fullAccess)
        let hasGoogle = GoogleAccountStore.shared.isConnected
        guard hasEventKit || hasGoogle else { return nil }

        guard let next = Self.countdownEvent(in: upcomingEvents, now: now) else { return nil }
        let title = next.title.trimmingCharacters(in: .whitespaces)
        let trimmed = title.count > 18 ? title.prefix(18) + "…" : title[...]
        return "\(trimmed) \(Self.countdownPhrase(until: next.startDate, now: now))"
    }

    /// How long a started meeting keeps the label, reading «now»: the tick
    /// lands exactly on its start, and a meeting is joined in its first
    /// minutes, not before it.
    static let countdownNowGraceSec: TimeInterval = 5 * 60

    /// The meeting the countdown is about: the first that has not been
    /// running longer than the grace, within the window. `upcomingEvents`
    /// includes meetings in progress (EventKit returns overlaps).
    static func countdownEvent(in events: [DaisyMeeting], now: Date) -> DaisyMeeting? {
        let cutoff = now.addingTimeInterval(upcomingWindowSec)
        return events.first {
            $0.startDate > now.addingTimeInterval(-countdownNowGraceSec) && $0.startDate <= cutoff
        }
    }

    /// «in 3h 5m» / «in 42m» / «now» — and the Russian «через 3 ч 5 мин».
    /// Minutes are rounded up, so «in 1m» never reads as «now» while the
    /// meeting has not started.
    nonisolated static func countdownPhrase(until start: Date, now: Date) -> String {
        let totalMinutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        guard totalMinutes > 0 else { return String(localized: "now", comment: "Menu bar: the next meeting starts right now") }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return String(localized: "in \(minutes)m", comment: "Menu bar countdown, under an hour")
        }
        if minutes == 0 {
            return String(localized: "in \(hours)h", comment: "Menu bar countdown, whole hours")
        }
        return String(localized: "in \(hours)h \(minutes)m", comment: "Menu bar countdown, hours and minutes")
    }
}

// MARK: - EKEvent → DaisyMeeting projection

private extension DaisyMeeting {
    nonisolated init?(ekEvent: EKEvent) {
        // `eventIdentifier` is technically optional on EKEvent but in
        // practice is always present for store-fetched events.
        guard let localID = ekEvent.eventIdentifier else { return nil }

        let detected = Self.detectMeetingURL(in: ekEvent)
        let cgColor = ekEvent.calendar?.cgColor
        let hex = cgColor.flatMap(Self.hexString(from:))
        let names = Self.projectAttendees(ekEvent.attendees)
        let emails = Self.projectAttendeeEmails(ekEvent.attendees)

        self.init(
            externalID: ekEvent.calendarItemExternalIdentifier,
            localID: localID,
            title: ekEvent.title ?? "Untitled",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate ?? ekEvent.startDate.addingTimeInterval(3600),
            location: ekEvent.location,
            notes: ekEvent.notes,
            meetingURL: detected?.url,
            meetingPlatform: detected?.platform,
            calendarColorHex: hex,
            attendees: names,
            attendeeEmails: emails
        )
    }

    /// Extract raw email addresses from EKParticipant list. Best-
    /// effort — EventKit gives us `mailto:foo@bar.com` URLs for
    /// invited people; anything that doesn't fit that shape is
    /// skipped. Used to detect the dominant external domain for
    /// auto-suggested client tagging (see RecordingSession), and to
    /// resolve invitees to saved speaker profiles.
    ///
    /// Excludes the user, for the same reasons as `projectAttendees` —
    /// and additionally because the user's own address is by definition
    /// never the "dominant external domain", so including it only added
    /// noise to the client-tag inference.
    nonisolated static func projectAttendeeEmails(_ raw: [EKParticipant]?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for p in raw {
            if p.isCurrentUser { continue }
            guard let url = p.url as URL? else { continue }
            let s = url.absoluteString
            let email: String
            if s.hasPrefix("mailto:") {
                email = String(s.dropFirst("mailto:".count))
            } else if s.contains("@") {
                email = s
            } else {
                continue
            }
            let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
            guard normalized.contains("@"), !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                out.append(normalized)
            }
        }
        return out
    }

    /// Extract human-readable display names from EKParticipant list.
    /// Falls back to URL last-path component (typically email user
    /// portion) when `.name` is nil — common for Google Calendar
    /// events synced via CalDAV where iOS gets only email addresses.
    /// Deduplicates and trims.
    ///
    /// **Excludes the user themselves** (`isCurrentUser`), which is what
    /// the Google path has always done and what its comment already
    /// claimed this one did. Every consumer wants the OTHER people:
    /// the pre-meeting brief is about who you're meeting, the speaker
    /// rename picker offers names for REMOTE voices, the diarizer hint
    /// counts remote speakers, and — the reason this was found —
    /// `SpeakerNameSuggester` uses this list as the allow-list of names
    /// a diarized remote speaker may be given. With the user in it, a
    /// transcript line like "спасибо, Егор" (the other party thanking
    /// the person recording) was enough for the model to propose the
    /// USER as the name for a remote speaker, and one Confirm would
    /// then attribute the other party's words to them.
    nonisolated static func projectAttendees(_ raw: [EKParticipant]?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for p in raw {
            if p.isCurrentUser { continue }
            let name = p.name?.trimmingCharacters(in: .whitespaces)
            let display: String
            if let name, !name.isEmpty {
                display = name
            } else if let url = p.url as URL?,
                      url.scheme == "mailto" || url.absoluteString.contains("@") {
                // mailto:alex@company.com → "alex"
                let local = url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .split(separator: "@").first.map(String.init) ?? ""
                if local.isEmpty { continue }
                display = local
            } else {
                continue
            }
            if seen.insert(display.lowercased()).inserted {
                out.append(display)
            }
        }
        return out
    }

    /// Inspect location → url → notes for a known meeting platform
    /// URL. Order matters: location is where most Zoom invites end
    /// up, then EKEvent.url (Apple Calendar's native URL field),
    /// then notes (Google Calendar dumps the link here).
    nonisolated static func detectMeetingURL(in event: EKEvent) -> (platform: String, url: URL)? {
        let haystacks: [String] = [
            event.location,
            event.url?.absoluteString,
            event.notes,
        ].compactMap { $0 }

        for text in haystacks {
            for (platform, pattern) in meetingPatterns {
                if let match = text.range(of: pattern, options: .regularExpression) {
                    let raw = String(text[match])
                    if let url = URL(string: raw) {
                        return (platform, url)
                    }
                }
            }
        }
        return nil
    }

    /// Platform → regex pattern. We use NSRegularExpression-style
    /// patterns (Swift's `firstMatch(of: #/.../#)` is slick but the
    /// closed-over Regex type complicates an array of tuples).
    nonisolated static let meetingPatterns: [(platform: String, pattern: String)] = [
        ("zoom",    #"https?://[\w.-]*zoom\.us/(?:j|my|wc|s)/[^\s<>"']+"#),
        ("meet",    #"https?://meet\.google\.com/[a-z0-9\-]+(?:\?[^\s<>"']*)?"#),
        ("teams",   #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#),
        ("webex",   #"https?://[\w.-]*webex\.com/(?:meet/[^\s<>"']+|[^\s<>"']*/j\.php\?[^\s<>"']+)"#),
        ("whereby", #"https?://whereby\.com/[\w\-]+"#),
        ("jitsi",   #"https?://meet\.jit\.si/[^\s<>"']+"#),
    ]

    /// Calendar colour → hex like "#7BAE8E".
    nonisolated static func hexString(from color: CGColor) -> String? {
        guard let comps = color.components, comps.count >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
