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
import NaturalLanguage
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

    /// The card is showing the line built from the calendar, not a model's
    /// lede. It is never the "already have today's lede" of `prepare`, so
    /// open items that finish loading still get their real lede.
    @ObservationIgnored
    private var showingCalendarLine = false

    /// Bumped whenever a newer answer replaces the one in flight, so a slow
    /// model reply can't land over the calendar line it no longer describes.
    @ObservationIgnored
    private var ledeRequestID = 0

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
        // `-checked`: a lede cached by an earlier build went through no
        // grounding check and may name people who don't exist.
        let today = Self.ledeDayKey(isTomorrow: scope.isTomorrow)
        let events = scope.events
        // The brief's lede goes to the summary provider: a voice note's
        // steps only as the note itself could go there (07.11). The card
        // still shows every open step — it reads the store, not this.
        let openItems = Self.itemsForProvider(ActionItemStore.shared.openItems, gate: .current)
        /* With no open items the prompt's "weave in the open loops" has
           nothing to work with, and the on-device model filled the gap with
           invented people and reports (Maria, Tom, Claire, Mark). The
           calendar line needs no model and no consent. The cached lede is
           left alone: on a cold launch the items may simply not be loaded. */
        guard !openItems.isEmpty else {
            showCalendarLine(events: events, isTomorrow: scope.isTomorrow)
            return
        }
        // Already have this day's lede in memory — nothing to do.
        if !force, generatedDayKey == today, !showingCalendarLine, case .ready = ledeState { return }
        // Relaunched the same day: restore the persisted lede instead of
        // re-running the LLM (local) or re-prompting for consent (cloud).
        if !force, generatedDayKey == today, let cached = cachedSummary {
            // Empty: today's lede was rejected. Don't ask the model again,
            // and write the line from the events still on the agenda.
            if cached.summary.isEmpty {
                showCalendarLine(events: events, isTomorrow: scope.isTomorrow)
            } else {
                showingCalendarLine = false
                ledeState = .ready(cached)
            }
            return
        }
        if case .generating = ledeState { return }

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

        ledeRequestID += 1
        let requestID = ledeRequestID
        ledeState = .generating
        let dossier = Self.buildDossier(
            events: events, openItems: openItems, isTomorrow: scope.isTomorrow
        )
        do {
            /* A task of its own: the card's `.task(id:)` cancels this prepare
               whenever the agenda changes, and a cancelled model call would
               leave the card with no intro. The guards below drop a reply
               that has gone stale. */
            let summary = try await Task {
                try await Summarizer.shared.runProbe(
                    transcript: dossier,
                    title: "Morning brief",
                    localeHint: nil,
                    task: .morningBrief
                )
            }.value
            // First successful cloud brief = standing consent for later days.
            if !providerLocal { cloudBriefConsented = true }
            guard requestID == ledeRequestID else { return }
            /* The card's re-keyed prepare returned early while this request
               ran, so a roll-over to another day is picked up here. */
            let current = Self.briefScope()
            guard Self.ledeDayKey(isTomorrow: current.isTomorrow) == today else {
                ledeState = .idle
                await prepare(settings: settings)
                return
            }
            generatedDayKey = today
            guard !summary.summary.isEmpty, DayBriefLede.isGrounded(summary.summary, in: dossier) else {
                log.warning("Morning brief lede named something outside its input; using the calendar line")
                cachedSummary = Self.ledeSummary("")
                showCalendarLine(events: current.events, isTomorrow: current.isTomorrow)
                return
            }
            showingCalendarLine = false
            ledeState = .ready(summary)
            cachedSummary = summary
            log.info("Morning brief lede ready (\(events.count) meetings, \(openItems.count) open items)")
        } catch {
            guard requestID == ledeRequestID else { return }
            log.error("Morning brief lede failed: \(error.localizedDescription, privacy: .public)")
            guard Self.ledeDayKey(isTomorrow: Self.briefScope().isTomorrow) == today else {
                ledeState = .idle
                await prepare(settings: settings)
                return
            }
            ledeState = .unavailable
        }
    }

    private static func ledeDayKey(isTomorrow: Bool) -> String {
        UsageStats.dayKey(for: Date()) + (isTomorrow ? "-tomorrow" : "-today") + "-checked"
    }

    private func showCalendarLine(events: [DaisyMeeting], isTomorrow: Bool) {
        ledeRequestID += 1
        showingCalendarLine = true
        ledeState = DayBriefLede.calendarLine(events: events, isTomorrow: isTomorrow)
            .map { .ready(Self.ledeSummary($0)) } ?? .unavailable
    }

    private static func ledeSummary(_ text: String) -> MeetingSummary {
        MeetingSummary(summary: text, sections: [], actionItems: [], clientFollowUp: "")
    }

    /// The open steps the lede's request may carry to the provider the
    /// gate describes: every meeting's; a voice note's only when the
    /// voice-note gate would let the note go there (`VoiceNoteProfile.mayFeed`).
    static func itemsForProvider(_ items: [TrackedActionItem], gate: VoiceNoteProfile.Gate) -> [TrackedActionItem] {
        items.filter { VoiceNoteProfile.mayFeed(isVoiceNote: $0.fromVoiceNote, kindKnown: $0.kindKnown, recordedAt: $0.sessionDate, gate: gate) }
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

/// The parts of the card's intro that don't depend on a model answering
/// well: a line written from the calendar, and the check on a model's lede.
nonisolated enum DayBriefLede {
    /// "First up tomorrow: Lunch at 12:00." The header already counts the
    /// events. An all-day event has no time worth reading out, so the first
    /// timed event leads; nil when there is nothing on the calendar.
    static func calendarLine(
        events: [DaisyMeeting],
        isTomorrow: Bool,
        calendar: Calendar = .current,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> String? {
        guard let first = events.first else { return nil }
        guard let timed = events.first(where: { !isAllDay($0, calendar: calendar) }) else {
            return isTomorrow
                ? String(localized: "Tomorrow: \(first.title).")
                : String(localized: "Today: \(first.title).")
        }
        let at = time(timed.startDate)
        return isTomorrow
            ? String(localized: "First up tomorrow: \(timed.title) at \(at).")
            : String(localized: "First up today: \(timed.title) at \(at).")
    }

    private static func isAllDay(_ event: DaisyMeeting, calendar: Calendar) -> Bool {
        event.startDate == calendar.startOfDay(for: event.startDate)
            && event.endDate.timeIntervalSince(event.startDate) >= 23 * 3600
    }

    /* False when the lede names someone or something the dossier doesn't.
       NLTagger alone isn't enough: it found Maria and Tom but not Mark, and
       nothing in Russian. So any capitalized word past a sentence's start
       has to come from the dossier too. A false alarm costs only the
       model's prose: the card falls back to the calendar line. */
    @MainActor
    static func isGrounded(_ lede: String, in dossier: String) -> Bool {
        // Only capitalized: the verb in "mark the invoice paid" is not Mark.
        let known = Set(words(in: dossier).filter { $0.first?.isUppercase == true }.map(fold))
        return namesToCheck(in: lede).allSatisfy { name in
            let folded = fold(name)
            return known.contains(folded)
                || commonWords.contains(folded)
                || known.contains { isInflection(folded, of: $0) }
        }
    }

    @MainActor
    private static func namesToCheck(in text: String) -> [String] {
        var names: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .personalName { names += words(in: String(text[range])) }
            return true
        }
        // German capitalizes every noun, so capitals say nothing there.
        guard NLLanguageRecognizer.dominantLanguage(for: text) != .german else { return names }

        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        sentences.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = words(in: String(text[range]))
            names += sentence.dropFirst().filter {
                $0.count > 1 && $0.first?.isUppercase == true
            }
            if let opener = sentence.first, mayBeRussianName(opener) { names.append(opener) }
            return true
        }
        return names
    }

    /* NLTagger finds no Russian names, and a sentence's first word is
       capitalized anyway. A word the Russian dictionary only knows
       capitalized is a name; the list holds names that are also ordinary
       lowercase words there. Without the dictionary, assume a name. */
    @MainActor
    private static func mayBeRussianName(_ word: String) -> Bool {
        guard word.count > 1, word.first?.isUppercase == true, isCyrillic(word) else { return false }
        if russianNamesThatAreAlsoWords.contains(russianStem(fold(word))) { return true }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains("ru") else { return true }
        return checker.checkSpelling(
            of: word.lowercased(), startingAt: 0, language: "ru",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location != NSNotFound
    }

    /// Stems, so "Марку" and "Вере" count as well as "Марк" and "Вера".
    private static let russianNamesThatAreAlsoWords: Set<String> = Set(
        ["Марк", "Иван", "Том", "Катя", "Роман", "Вера", "Надежда", "Любовь", "Любви", "Лев", "Льва", "Роза", "Лиля", "Макс", "Глеб", "Слава", "Саша", "Паша", "Маша", "Даша", "Миша", "Коля", "Толя", "Юля", "Оля", "Женя", "Ваня",
         "Илья", "Максим", "Костя", "Соня", "Рома", "Майя", "Лилия", "Люба", "Валя", "Дима", "Лена", "Таня", "Настя", "Нина", "Галя", "Зина", "Тома", "Гена", "Вова", "Витя", "Петя", "Федя", "Гриша", "Лёша", "Серёжа", "Алла", "Инна", "Яна", "Ира", "Света", "Лариса", "Кира", "Ника", "Дина", "Жанна", "Ян", "Артём", "Тимур", "Денис", "Кирилл", "Егор"]
            .map { russianStem(fold($0)) }
    )

    /// A folded word without its case ending: Мария, Марии and Марией all
    /// give "мари"; Марк gives "марк" and март gives "март".
    private static func russianStem(_ folded: String) -> String {
        for ending in ["ои", "еи", "ом", "ем", "ью", "а", "я", "у", "ю", "е", "и", "ы", "ь"]
        where folded.hasSuffix(ending) && folded.count - ending.count >= 2 {
            return String(folded.dropLast(ending.count))
        }
        return folded
    }

    private static func isCyrillic(_ word: String) -> Bool {
        word.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    private static func words(in text: String) -> [String] {
        var out: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // "Tom's" is Tom.
            let word = text[range].split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? ""
            if word.contains(where: \.isLetter) { out.append(word) }
            return true
        }
        return out
    }

    private static func fold(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Russian declines names: the dossier's "Мария" is "Марии" in a lede.
    private static func isInflection(_ word: String, of known: String) -> Bool {
        isCyrillic(word) && isCyrillic(known) && russianStem(word) == russianStem(known)
    }

    /// Days and months are capitalized in English without being anyone.
    private static let commonWords: Set<String> = {
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US")
        return Set((english.weekdaySymbols + english.monthSymbols + ["Today", "Tomorrow"]).map(fold))
    }()
}
