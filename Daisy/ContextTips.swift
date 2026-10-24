//
//  ContextTips.swift
//  Daisy
//
//  The tips that replaced the tour's setup screens (Onboarding 2.0,
//  package E, Egor 23–24.10). The tour no longer asks about the calendar
//  or the summary provider; Daisy asks once, at the moment it matters:
//
//   • Calendar — the first time a meeting app Daisy knows launches, or on
//     the first launch of a day after the tour, while no calendar is
//     connected: «Подключить календарь?» → Settings → Connections. Not on
//     the dictation-only path until the person records a meeting.
//   • Summary provider — a meeting ended and no provider can write its
//     summary (the «No summary — …» toast already says why; this is the
//     one-time nudge beside it) → Settings → Summary.
//   • Project — a Daisy-key note said «в проект X» and there is no X: the
//     misfiled-note message offers «Создать «X»» instead of «Move», once
//     (DaisyKeyController builds the message; the name and the create +
//     move live here).
//
//  The same pattern as `StyleProfileTip`: each tip once per install,
//  persisted; never over a recording, a dictation, a Daisy-key command,
//  the tour or another pill — a tip that came up then waits (persisted,
//  so a quit doesn't lose it) and is retried on a timer and at the next
//  trigger. There is no banner fallback: a banner can carry no button,
//  and a silent one would spend the only ask on nothing. Nothing under
//  the test host, which runs on the real prefs.
//

import AppKit
import EventKit
import Foundation

@MainActor
final class ContextTips {
    static let shared = ContextTips()

    enum Tip: String, CaseIterable, Sendable {
        case calendar
        case summaryProvider = "summary"
        case project
    }

    static let bubbleTag = "context-tip"
    /// Bool per tip: shown. Never cleared.
    static let shownKeyPrefix = "daisy.contextTips.shown."
    /// [String]: tips that came up while Daisy was busy.
    static let pendingKey = "daisy.contextTips.pending"
    /// The tour's path and when it ended — the tour clears its own state
    /// at the end, and the tips (and Home's checklist) still need both.
    static let tourPathKey = "daisy.contextTips.tourPath"
    static let tourFinishedKey = "daisy.contextTips.tourFinishedAt"

    private let defaults: UserDefaults
    private let isSuppressed: Bool
    /// A pill must wait: see `daisyIsBusy`.
    private let isBusy: @MainActor () -> Bool
    /// Only a capture or its processing — what the project offer checks:
    /// it rides on the note's own message, so another pill doesn't count.
    private let isCapturing: @MainActor () -> Bool
    private let showAsk: @MainActor (WidgetBubbleContent) -> Bool
    /// A calendar is connected, or the person already answered macOS's
    /// calendar question (a «no» there is theirs; Daisy doesn't re-ask).
    private let calendarSettled: @MainActor () -> Bool
    /// A meeting of the person's own is in the Library (not the demo);
    /// nil while the Library isn't loaded yet.
    private let meetingRecorded: @MainActor () -> Bool?
    /// Summaries are off, or the chosen provider can write one now; nil
    /// while the provider hasn't been checked yet.
    private let summaryReady: @MainActor () -> Bool?
    /// The widget's panel exists — an offer on a notification banner
    /// would have no button to take it.
    private let hasWidget: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let retryDelay: Duration
    private var retryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Ten minutes of retries; after that, the next trigger tries again.
    private static let maxRetries = 20

    init(
        defaults: UserDefaults = .standard,
        isSuppressed: Bool = TestHost.isActive,
        isBusy: @escaping @MainActor () -> Bool = ContextTips.daisyIsBusy,
        isCapturing: @escaping @MainActor () -> Bool = { RecordingSession.isCapturingOrTranscribing },
        showAsk: @escaping @MainActor (WidgetBubbleContent) -> Bool = { WidgetBubbleCenter.shared.show($0) },
        calendarSettled: @escaping @MainActor () -> Bool = {
            EKEventStore.authorizationStatus(for: .event) != .notDetermined
                || GoogleAccountStore.shared.isConnected
        },
        meetingRecorded: @escaping @MainActor () -> Bool? = {
            // Empty until the first refresh after launch — unknown, not «no».
            let sessions = SessionStore.shared.sessions
            return sessions.isEmpty ? nil : sessions.contains { $0.kind == .recording && !$0.isDemo }
        },
        summaryReady: @escaping @MainActor () -> Bool? = {
            if RecordingSession.current?.settings.autoSummarize == false { return true }
            switch Summarizer.shared.availability {
            case .unknown: return nil
            case .available: return true
            case .unavailable: return false
            }
        },
        hasWidget: @escaping @MainActor () -> Bool = { WidgetBubbleCenter.shared.host != nil },
        now: @escaping @MainActor () -> Date = { Date() },
        retryDelay: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.isSuppressed = isSuppressed
        self.isBusy = isBusy
        self.isCapturing = isCapturing
        self.showAsk = showAsk
        self.calendarSettled = calendarSettled
        self.meetingRecorded = meetingRecorded
        self.summaryReady = summaryReady
        self.hasWidget = hasWidget
        self.now = now
        self.retryDelay = retryDelay
    }

    /// `StyleProfileTip`'s idea of busy, plus the tour: its coach bubble
    /// is talking, and a tip there would answer a question nobody asked.
    static func daisyIsBusy() -> Bool {
        StyleProfileTip.daisyIsBusy()
            || OnboardingTourController.shared.isActive
            || TourBubbleCenter.shared.isShowing
    }

    func hasShown(_ tip: Tip) -> Bool {
        defaults.bool(forKey: Self.shownKeyPrefix + tip.rawValue)
    }

    var pending: [Tip] {
        (defaults.stringArray(forKey: Self.pendingKey) ?? []).compactMap(Tip.init(rawValue:))
    }

    // MARK: - The tour's record

    /// `OnboardingTourController.finish`: what the tips need from a tour
    /// that is about to forget itself.
    static func tourFinished(path: OnboardingTour.Path, at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(path.rawValue, forKey: tourPathKey)
        defaults.set(date, forKey: tourFinishedKey)
    }

    var tourPath: OnboardingTour.Path? {
        defaults.string(forKey: Self.tourPathKey).flatMap(OnboardingTour.Path.init(rawValue:))
    }

    var tourFinishedAt: Date? {
        defaults.object(forKey: Self.tourFinishedKey) as? Date
    }

    /// The person picked «just dictation» in the tour and hasn't recorded
    /// a meeting since: meeting things (the calendar tip, Home's meeting
    /// rows) are not for now. An unloaded Library counts as no meeting.
    var meetingsNotYet: Bool {
        tourPath == .dictationOnly && meetingRecorded() != true
    }

    // MARK: - Triggers

    /// At launch. Watches meeting-app launches and day changes for the
    /// calendar tip while it is still to come, and shows a tip a quit
    /// interrupted.
    func start() {
        guard !isSuppressed, observers.isEmpty else { return }
        if !hasShown(.calendar) {
            // Its own watch rather than MeetingDetector's: that one runs
            // only while auto-record is on, and the ask matters most when
            // it is off.
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      MeetingDetector.meetingBundleIDs().contains(bundleID) else { return }
                // A beat later: the same launch raises «Record this call?»,
                // which must land first — the tip then waits for it to go.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.meetingAppLaunched()
                }
            })
            // A new day is noticed when the person is there — Daisy
            // brought forward or the screens waking — not at midnight over
            // a locked Mac, where the one ask would go to nobody.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dayStarted() }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dayStarted() }
            })
            dayStarted()
        }
        showPendingIfCalm()
    }

    /// A meeting app Daisy knows just launched.
    func meetingAppLaunched() {
        request(.calendar)
    }

    /// Launch, activation or wake: a day after the tour's own day asks.
    func dayStarted() {
        guard let finished = tourFinishedAt else { return }
        let today = now()
        guard today > finished, !Calendar.current.isDate(today, inSameDayAs: finished) else { return }
        request(.calendar)
    }

    /// A meeting ended and summaries are on, but the provider can't write
    /// one (`RecordingSession`, where the «No summary» note is written).
    func summaryProviderMissing() {
        request(.summaryProvider)
    }

    func request(_ tip: Tip) {
        guard !isSuppressed, tip != .project, !hasShown(tip), isWanted(tip) != false else { return }
        if !pending.contains(tip) {
            defaults.set((pending + [tip]).map(\.rawValue), forKey: Self.pendingKey)
        }
        showPendingIfCalm()
    }

    /// Still worth asking — checked again at show time: the person may
    /// have connected the calendar or picked a provider in the meantime.
    /// nil: not known yet (right after launch) — kept waiting, not dropped.
    private func isWanted(_ tip: Tip) -> Bool? {
        switch tip {
        case .calendar:
            guard tourFinishedAt != nil, !calendarSettled() else { return false }
            guard tourPath == .dictationOnly else { return true }
            return meetingRecorded()
        case .summaryProvider:
            return summaryReady().map(!)
        case .project:
            return false
        }
    }

    /// Show the first tip still waiting, if Daisy is idle; else try again
    /// later. One pill at a time.
    func showPendingIfCalm(attempt: Int = 0) {
        guard !isSuppressed else { return }
        let waiting = pending.filter { !hasShown($0) && isWanted($0) != false }
        if waiting != pending {
            defaults.set(waiting.map(\.rawValue), forKey: Self.pendingKey)
        }
        guard !waiting.isEmpty else {
            retryTask?.cancel()
            retryTask = nil
            return
        }
        // The first one that is known to be wanted; the rest wait.
        guard let tip = waiting.first(where: { isWanted($0) == true }), !isBusy() else {
            scheduleRetry(attempt: attempt + 1)
            return
        }
        guard let content = Self.content(for: tip), showAsk(content) else {
            scheduleRetry(attempt: attempt + 1)
            return
        }
        retryTask?.cancel()
        retryTask = nil
        markShown(tip)
        defaults.set(waiting.filter { $0 != tip }.map(\.rawValue), forKey: Self.pendingKey)
        if tip == .calendar { stopWatching() }
    }

    private func markShown(_ tip: Tip) {
        defaults.set(true, forKey: Self.shownKeyPrefix + tip.rawValue)
    }

    private func stopWatching() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func scheduleRetry(attempt: Int) {
        guard attempt <= Self.maxRetries, retryTask == nil else { return }
        retryTask = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.showPendingIfCalm(attempt: attempt)
        }
    }

    /// The pill for a tip that has one; the project offer rides on the
    /// note's own message instead.
    static func content(for tip: Tip) -> WidgetBubbleContent? {
        switch tip {
        case .calendar:
            WidgetBubbleContent(
                text: Copy.calendarAsk, actionTitle: Copy.calendarAction, autoDismiss: 20, tag: bubbleTag,
                action: { openSettings(.connections, row: .calendarApple) })
        case .summaryProvider:
            WidgetBubbleContent(
                text: Copy.summaryAsk, actionTitle: Copy.summaryAction, autoDismiss: 20, tag: bubbleTag,
                action: { openSettings(.ai, row: .summaryProvider) })
        case .project:
            nil
        }
    }

    /// Daisy's window on a Settings tab — the morning-brief pill's window
    /// dance (`StyleProfileTip.openMyStyle`).
    static func openSettings(_ tab: SettingsTab, row: SettingsRow? = nil) {
        AppNavigation.shared.openInSettings(tab, row: row)
        if let open = WidgetBubbleCenter.shared.openMainWindow {
            open()
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    // MARK: - Project

    /// The name to offer for a note that said «в проект X» where there is
    /// no X — once, and only when nothing is being captured. Marks the
    /// tip shown: the caller puts the offer on screen.
    func projectOffer(for spoken: String, route: DaisyKeyFolderRoute.Result) -> String? {
        guard !isSuppressed, !hasShown(.project), route.unmatched, !route.ambiguous, !isCapturing(), hasWidget(),
              let name = Self.proposedProjectName(in: spoken) else { return nil }
        markShown(.project)
        return name
    }

    /// Words that end a spoken project name before the note goes on.
    nonisolated private static let nameEnders: Set<Character> = [",", ".", ":", ";", "!", "?", "…", "—", "–", "-"]
    nonisolated private static let closingQuotes: Set<Character> = ["»", "”", "\""]
    nonisolated private static let quotes = CharacterSet(charactersIn: "«»\"“”„'‘’")
    /// Words a name doesn't contain: «в проект, который мы обсуждали» is a
    /// sentence, not a project.
    nonisolated private static let notInNames: Set<String> = [
        "который", "которая", "которое", "которые", "что", "где", "мы", "я", "ты", "он", "она", "они", "это", "этот",
        "наш", "мой", "твой", "про", "о", "и", "или", "с", "по", "для", "на",
        "which", "that", "where", "we", "i", "you", "he", "she", "they", "it", "this", "our", "my", "your",
        "about", "and", "or", "with", "for", "on",
    ]

    /// «в проект Альфа, купить …» → «Альфа»: the one to three words after
    /// the folder phrase, when punctuation closes them — or one word that
    /// ends the text («в проект Лендинг»). Without a boundary «в проект
    /// Альфа купить молоко» could name any of its words; that, or anything
    /// longer, isn't a name Daisy can be sure of — nil, and the message
    /// stays as it was.
    nonisolated static func proposedProjectName(in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let start = DaisyKeyFolderRoute.nameStart(words)
        guard start > 0, start < words.count else { return nil }
        var name: [String] = []
        var closed = false
        var quotedName = false
        for word in words[start...] {
            if word.allSatisfy({ nameEnders.contains($0) }) { closed = true; break }
            if name.count == 3 { break }
            // «в проект «Новый сайт»» — a quoted name closes at its quote.
            if name.isEmpty { quotedName = word.first.map { "«“\"".contains($0) } ?? false }
            let ends = word.last.map { nameEnders.contains($0) || (quotedName && closingQuotes.contains($0)) } ?? false
            let bare = word.trimmingCharacters(in: quotes)
                .trimmingCharacters(in: CharacterSet(charactersIn: String(nameEnders)))
                .trimmingCharacters(in: quotes)
            guard bare.contains(where: \.isLetter) || bare.contains(where: \.isNumber),
                  !notInNames.contains(DaisyKeyIntentParser.normalized(bare)) else { return nil }
            name.append(bare)
            if ends { closed = true; break }
        }
        let lastWord = name.count == 1 && start + 1 == words.count
        guard !name.isEmpty, name.count <= 3, closed || lastWord else { return nil }
        let joined = name.joined(separator: " ")
        // «альфа» → «Альфа», but «iOS» and «iPhone» stay as they are.
        let letters = Array(joined)
        guard let first = letters.first, first.isLowercase, letters.count < 2 || !letters[1].isUppercase else { return joined }
        return first.uppercased() + joined.dropFirst()
    }

    /// «Создать «X»»: the project, then the note moved into it — the
    /// Library's own move. The folder, or nil when the note didn't move.
    static func createProject(
        named name: String,
        moving note: StoredSession.ID,
        addFolder: @MainActor (String) -> SessionFolder = { FolderStore.shared.addFolder(named: $0) },
        move: @MainActor (StoredSession.ID, SessionFolder) async -> Bool = ContextTips.moveNote
    ) async -> SessionFolder? {
        let folder = addFolder(name)
        guard folder.slug != SessionFolder.inbox.slug else { return nil }
        return await move(note, folder) ? folder : nil
    }

    static func moveNote(_ id: StoredSession.ID, to folder: SessionFolder) async -> Bool {
        let store = SessionStore.shared
        if !store.sessions.contains(where: { $0.id == id }) { await store.refresh() }
        guard let note = store.sessions.first(where: { $0.id == id }) else { return false }
        await store.moveSession(note, to: folder)
        return store.sessions.first(where: { $0.id == id })?.folderSlug == folder.slug
    }

    // MARK: - Copy

    /// Every line of the tips, keyed (`tip.*`) with both languages in
    /// Localizable.xcstrings, as the tour's are.
    enum Copy {
        static var calendarAsk: String { text("tip.calendar.ask") }
        static var calendarAction: String { text("tip.calendar.action") }
        static var summaryAsk: String { text("tip.summary.ask") }
        static var summaryAction: String { text("tip.summary.action") }
        /// «Проекта «X» нет — положила в «Входящие». Создать?»
        static func projectAsk(name: String, savedTo folder: String) -> String {
            String(format: text("tip.project.ask"), name, folder)
        }
        static func projectCreate(_ name: String) -> String { String(format: text("tip.project.create"), name) }
        static func projectCreated(_ name: String) -> String { String(format: text("tip.project.created"), name) }
        static func projectNotMoved(_ folder: String) -> String { String(format: text("tip.project.notMoved"), folder) }
        static var homeSummaryCaption: String { text("tip.home.summary.caption") }
        static var whatsNewTour: String { text("tip.whatsNew.tour") }

        static func text(_ key: String) -> String {
            String(localized: String.LocalizationValue(stringLiteral: key))
        }
    }
}
