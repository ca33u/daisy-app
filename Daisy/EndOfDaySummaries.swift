//
//  EndOfDaySummaries.swift
//  Daisy
//
//  Runs the summarizer over the day's meetings, once a day, at an hour
//  the user picks.
//
//  "The day's meetings" is expressed as "recordings that still have no
//  summary", not as "recordings started today". Same set on any normal
//  evening — everything older already got one — but it self-heals:
//  a night the provider was down, an interrupted pass, and a meeting
//  recorded at 21:00 after the pass already ran are all picked up next
//  evening, with no bookkeeping about what was attempted when.
//
//  Why this exists: summarizing inline after Stop puts a heavy LLM pass
//  on the machine at the exact moment the user has finished the meeting
//  and wants the laptop back — and it lands there right after the final
//  Whisper pass, speaker matching and screen OCR have already run. With
//  a cloud provider nobody notices. With a local model that pile-up is
//  what "Daisy melts my Mac" means in practice (Ken, 2026-07-29). The
//  work still has to happen; it just doesn't have to happen THEN.
//
//  Deliberately a poll, not a scheduled timer. A `Timer` set for 20:00
//  does not fire while the Mac is asleep and does not exist while the
//  app is quit — the two states a laptop spends its evening in. Asking
//  "has today's slot passed, and have we run today?" every few minutes
//  answers correctly after a wake, after a relaunch, and after the
//  machine was shut at 19:00 and opened at 23:00. The persisted
//  last-run DAY is the whole state.
//

import AppKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class EndOfDaySummaries {
    static let shared = EndOfDaySummaries()

    enum State: Equatable {
        case idle
        /// Working on `current` of `total`, 1-based — it's a label for a
        /// human, not an array index.
        case running(current: Int, total: Int)
    }

    private(set) var state: State = .idle

    /// Safety net, not the rule. A pass takes THE DAY'S meetings —
    /// which in practice is everything unsummarized, because anything
    /// older already has a summary from a previous evening. This bound
    /// only matters when something went wrong: a first run on an install
    /// with months of history, or a week away from the machine. Without
    /// it, turning the setting on could sweep a year into one night's
    /// API bill. Older sessions stay reachable through Re-summarize.
    ///
    /// Deliberately NOT a session count. The day is its own bound —
    /// nobody records forty meetings between breakfast and eight — and a
    /// count cap would split a normal Tuesday across two evenings for no
    /// reason (Egor, 2026-07-29).
    nonisolated static let maxLookbackDays = 7

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "EndOfDaySummaries")
    @ObservationIgnored
    private var timer: Timer?
    @ObservationIgnored
    private var runTask: Task<Void, Never>?
    @ObservationIgnored
    private weak var settings: AppSettings?
    /// The live recorder — a pass must never compete with one. Weak, and
    /// a nil read counts as BUSY: a guard whose job is "don't run while
    /// the user is recording" has to fail closed.
    @ObservationIgnored
    private weak var session: RecordingSession?
    /// Day we last told the user the provider was down, so a dead
    /// endpoint doesn't toast every five minutes all evening.
    /// Persisted: an evening of opening and closing the laptop would
    /// otherwise repeat the same warning on every launch.

    private static let lastRunKey = "daisy.endOfDaySummaries.lastRunDay"
    private static let warnedDayKey = "daisy.endOfDaySummaries.warnedUnavailableDay"

    private init() {}

    // MARK: - Wiring

    /// Start (or restart) polling. Idempotent; call again when the
    /// setting changes. Stops the poll entirely for any timing other
    /// than `.endOfDay`, so the common cases cost nothing.
    func apply(settings: AppSettings, session: RecordingSession) {
        self.settings = settings
        self.session = session
        timer?.invalidate()
        timer = nil
        guard settings.summaryTiming == .endOfDay else {
            // Switching the setting off has to stop a pass that is
            // ALREADY running. On a cloud provider that pass is
            // unattended spend, and continuing it after the user said
            // stop is the one thing this must not do.
            stop()
            return
        }
        // Five minutes: the trigger is an hour boundary, so precision
        // beyond this buys nothing and costs a wakeup.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Catch the case this exists for: the Mac was asleep or the app
        // was quit when the hour passed.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        runTask?.cancel()
    }

    // MARK: - Trigger

    private func tick() {
        guard let settings, settings.summaryTiming == .endOfDay else { return }
        guard runTask == nil else { return }
        // Never while recording: the entire point is to keep the heavy
        // pass away from the machine when it's busy with the user.
        guard !isBusyRecording else { return }
        guard shouldRunNow(hour: settings.endOfDaySummaryHour) else { return }
        runTask = Task { [weak self] in
            await self?.runPass()
            self?.runTask = nil
        }
    }

    /// Nil session ⇒ busy. We can't see what the recorder is doing, and
    /// the cost of waiting five minutes is nothing next to the cost of
    /// starting a batch of LLM passes on top of a live recording.
    private var isBusyRecording: Bool {
        guard let session else { return true }
        return session.status == .recording || session.status == .paused
    }

    /// Decide and run. Everything that could make the decision wrong
    /// happens BEFORE `markRanToday`, so a day is only burned once
    /// something has actually been looked at.
    private func runPass() async {
        // Provider FIRST, and unconditionally. `availability` never
        // returns to `.unknown` once probed, so a "probe only if
        // unknown" check would read a cached verdict forever — the
        // provider comes back at 20:30 and this path, which exists to
        // be the retry, would keep believing it's down. Probing costs a
        // keychain read for cloud providers and a 2 s loopback call for
        // local ones; this runs at most once per five minutes.
        //
        // Ahead of the store refresh on purpose: a broken provider
        // would otherwise pay a full session rescan on every retry
        // until midnight.
        await Summarizer.shared.refreshAvailability()
        guard let settings, settings.summaryTiming == .endOfDay else { return }
        if case .unavailable(let reason) = Summarizer.shared.availability {
            // Day deliberately NOT marked: nothing was attempted, so the
            // right retry is the next tick, not tomorrow.
            log.error("End-of-day summaries skipped — provider unavailable: \(reason, privacy: .public)")
            let today = Self.dayKey(Date())
            // Against the store as already loaded, not a fresh scan —
            // and at launch that store is empty, which correctly means
            // "we don't know of anything pending yet, don't cry wolf".
            // Meetings only: voice notes are left quietly when the provider
            // can't run (07.11).
            if Self.pendingSessions().contains(where: { $0.kind == .recording }),
               UserDefaults.standard.string(forKey: Self.warnedDayKey) != today {
                UserDefaults.standard.set(today, forKey: Self.warnedDayKey)
                ToastCenter.shared.show(
                    String(localized: "Couldn't summarize tonight — the summary provider isn't available."),
                    style: .warning,
                    duration: .seconds(8)
                )
            }
            return
        }

        // `applyAll` runs from `DaisyApp.init`, before the first
        // `SessionStore.refresh()` — so the very first tick sees an
        // EMPTY store. Marking the day off that would silently skip a
        // real backlog, on precisely the path this exists for: a laptop
        // opened at 23:00 after the hour has passed.
        await SessionStore.shared.refresh()
        // `refresh()` is not cancellation-aware, so it completes even
        // after `stop()`. Without this the day would be marked done for
        // a pass the user just switched off — and switching back the
        // same evening would then do nothing until tomorrow.
        guard !Task.isCancelled, settings.summaryTiming == .endOfDay else { return }
        let pending = Self.pendingSessions()

        // Mark before running, not after. An interrupted pass then costs
        // one day — acceptable because nothing is lost: the sessions it
        // didn't reach still have no summary, so tomorrow's pass takes
        // them. Marking afterwards would instead re-run the whole batch
        // every five minutes for the rest of any evening the user
        // interrupted.
        markRanToday()
        guard !pending.isEmpty else { return }
        await run(pending)
    }

    /// True once today's hour has passed and today's pass hasn't run.
    private func shouldRunNow(hour: Int, now: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard calendar.component(.hour, from: now) >= hour else { return false }
        return UserDefaults.standard.string(forKey: Self.lastRunKey) != Self.dayKey(now)
    }

    private func markRanToday(now: Date = Date()) {
        UserDefaults.standard.set(Self.dayKey(now), forKey: Self.lastRunKey)
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Selection

    /// Recordings with a transcript and no summary, NEWEST first — and
    /// voice notes recorded with their key that their gate lets through
    /// (`VoiceNoteProfile.Gate`, Egor 07.11): on this Mac, or with a cloud
    /// provider only those recorded since the switch was turned on — the
    /// window below must not carry a week of notes out the evening it is.
    /// The evening pass is the meetings' «Summarize» setting, and voice
    /// notes follow it. A voice note from before the key is never picked
    /// up here. Each is checked again right before it is sent
    /// (`mayStillSummarize`).
    ///
    /// "No summary" is the whole state machine: a session leaves this
    /// list by getting one, so an interrupted pass, a night the provider
    /// was down, and a meeting recorded at 21:00 after the pass already
    /// ran are all picked up by the next evening without any bookkeeping
    /// about what was attempted when. That self-healing is why the
    /// window is a few days wide rather than literally today — a
    /// today-only rule would silently abandon the 21:00 meeting, since
    /// tomorrow's pass would no longer consider it.
    static func pendingSessions() -> [StoredSession] {
        let declines = VoiceNoteProfile.Declines()
        let provider = Summarizer.shared.providerKind.rawValue
        return pending(in: SessionStore.shared.sessions, now: Date(), gate: .current,
                       isProcessing: { SessionStore.shared.isProcessing($0) },
                       declined: { declines.declined($0, by: provider) })
    }

    /// `pendingSessions` over a given list — the selection, apart from the
    /// store, for the tests. `declined`: a voice note this provider already
    /// couldn't do (`VoiceNoteProfile.Declines`) — not tried every evening
    /// until the provider is another one or the person asks.
    static func pending(in sessions: [StoredSession], now: Date, gate: VoiceNoteProfile.Gate,
                        isProcessing: (String) -> Bool, declined: (String) -> Bool) -> [StoredSession] {
        let cutoff = now.addingTimeInterval(-Double(maxLookbackDays) * 86_400)
        return sessions
            .filter { mayStillSummarize($0, gate: gate) && !$0.isDemo }
            .filter { !$0.isVoiceNote || !declined($0.id) }
            .filter { $0.summary == nil }
            .filter { !$0.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { $0.startedAt >= cutoff }
            // Screenshot links and headings only: `Summarizer` refuses
            // them, and a refusal every night would read as a failure.
            .filter { TranscriptSpeech.hasSpeech($0.transcriptText) }
            // Its final pass or a queue job is still on it: the transcript
            // is a draft, and the summary waits for the real one.
            .filter { !isProcessing($0.id) }
            // Newest first, because anything that stops the pass early
            // — the failure breaker, a recording starting, the user
            // switching the setting off — should cost the OLDEST work,
            // not today's. Oldest-first would let three permanently
            // failing sessions from Monday (a local model that can't fit
            // them, say) trip the breaker before tonight's meetings are
            // reached, every evening, until they age past the cutoff.
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - The pass

    private func run(_ batch: [StoredSession]) async {
        log.info("End-of-day summaries: \(batch.count, privacy: .public) session(s)")
        state = .running(current: 1, total: batch.count)
        let notes = batch.filter(\.isVoiceNote).count
        // A batch of voice notes alone starts quietly (07.11): each may yet
        // be left without a summary — its gate closed, a provider that
        // can't do it — and a «Summarizing…» with nothing after it would
        // be a promise the pass didn't keep. What came out is said below.
        var startToast: UUID?
        if let text = Self.startText(meetings: batch.count - notes, voiceNotes: notes) {
            ToastCenter.shared.show(text, style: .info)
            startToast = ToastCenter.shared.current?.id
        }

        var succeeded = 0
        var attempted = 0
        /// Meetings among them — the failure toast names what failed.
        var attemptedMeetings = 0
        var consecutiveFailures = 0
        /// The user stopped us (started recording, or changed the
        /// setting). Any failures so far were real, but blaming the
        /// provider for a stop the user asked for reads as a lie.
        var stoppedByUser = false
        for (index, session) in batch.enumerated() {
            if Task.isCancelled { break }
            // Re-check between sessions: the user may have started
            // recording since the pass began, and finishing the batch
            // would be exactly the CPU contention this avoids.
            if isBusyRecording {
                log.info("End-of-day summaries paused — a recording started")
                stoppedByUser = true
                break
            }
            // …and may have changed their mind about the whole feature
            // while we were awaiting the last provider call.
            guard self.settings?.summaryTiming == .endOfDay else {
                log.info("End-of-day summaries stopped — timing changed mid-pass")
                stoppedByUser = true
                break
            }
            // A voice note's gate, read again right before it is sent: the
            // batch was chosen before the provider calls that came first,
            // and the switch or the provider may have changed since (07.11).
            // Left without a summary — nothing failed.
            guard Self.mayStillSummarize(session, gate: .current) else {
                log.info("End-of-day summaries: a voice note's gate closed — left without a summary")
                continue
            }
            state = .running(current: index + 1, total: batch.count)
            attempted += 1
            if session.kind == .recording { attemptedMeetings += 1 }
            switch await summarize(session) {
            case .summarized:
                succeeded += 1
                consecutiveFailures = 0
            case .leftQuietly:
                // The provider can't do this voice note (too long, a
                // language it doesn't write): not a broken provider.
                attempted -= 1
                if session.kind == .recording { attemptedMeetings -= 1 }
            case .failed:
                consecutiveFailures += 1
                // Three in a row is a broken provider, not three unlucky
                // transcripts. Keep going and we spend twenty more
                // minutes proving it.
                if consecutiveFailures >= 3 {
                    log.error("End-of-day summaries aborted after 3 consecutive failures")
                    break
                }
            }
        }

        state = .idle
        // Nothing to say after all (every voice note left quietly, or the
        // person stopped it): the start toast doesn't stay behind.
        if let startToast { ToastCenter.shared.dismiss(id: startToast) }
        if succeeded > 0 {
            ToastCenter.shared.show(Self.doneText(succeeded: succeeded, withVoiceNotes: notes > 0), style: .success)
        } else if attempted > 0, !stoppedByUser {
            // Silence here would read as "nothing needed doing", which
            // is the opposite of what happened.
            ToastCenter.shared.showAction(
                Self.failureText(meetingsFailed: attemptedMeetings > 0),
                actionLabel: String(localized: "Summary settings"),
                style: .error,
                duration: .seconds(8)
            ) {
                AppNavigation.shared.openInSettings(.ai, row: .summaryProvider)
            }
        }
    }

    /// What the pass says when it starts. Meetings alone: as it always
    /// said. With voice notes (07.11) it names them, with the count after
    /// a colon so neither language has to decline it. Voice notes alone:
    /// nothing — see `run`.
    static func startText(meetings: Int, voiceNotes: Int) -> String? {
        guard meetings > 0 else { return nil }
        if voiceNotes == 0 {
            return meetings == 1
                ? String(localized: "Summarizing 1 meeting…")
                : String(localized: "Summarizing \(meetings) meetings…")
        }
        return String(localized: "Summarizing meetings and voice notes: \(meetings + voiceNotes)…")
    }

    /// What the pass says when nothing came out: tonight's meetings, as it
    /// always said, or tonight's voice notes when no meeting was among
    /// what failed (07.11).
    static func failureText(meetingsFailed: Bool) -> String {
        meetingsFailed
            ? String(localized: "Couldn't summarize tonight's meetings — check \(SettingsRow.summaryProvider.path).")
            : String(localized: "Couldn't summarize tonight's voice notes — check \(SettingsRow.summaryProvider.path).")
    }

    /// What the pass says when something was summarized.
    static func doneText(succeeded: Int, withVoiceNotes: Bool) -> String {
        if withVoiceNotes { return String(localized: "Summaries done: \(succeeded).") }
        return succeeded == 1
            ? String(localized: "1 meeting summarized.")
            : String(localized: "\(succeeded) meetings summarized.")
    }

    /// Whether a session from the store is the evening pass's to summarize:
    /// a recording, or a voice note its gate lets through (07.11). Asked
    /// when the batch is chosen and again right before each send.
    static func mayStillSummarize(_ session: StoredSession, gate: VoiceNoteProfile.Gate) -> Bool {
        session.kind == .recording
            || VoiceNoteProfile.summarizesOnItsOwn(session.voiceNote, recordedAt: session.startedAt, gate: gate)
    }

    enum Outcome { case summarized, failed, leftQuietly }

    /// One session. `.failed` on any failure — the session simply keeps
    /// its missing summary and is picked up by tomorrow's pass, which is a
    /// better retry than anything scheduled here. `.leftQuietly`: a voice
    /// note the provider can't do (too long for the on-device model, a
    /// language it doesn't write) — no failure, and no toast pointing at
    /// the provider settings for a summary nobody asked for.
    private func summarize(_ session: StoredSession) async -> Outcome {
        SessionStore.shared.beginGenerating(session.id)
        defer { Task { await SessionStore.shared.finishGenerating(session.id) } }

        // Same resolver the post-stop path uses, so a deferred summary
        // can't come out in a different language than an inline one
        // would have.
        let localeHint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage
        )
        guard let summary = await Summarizer.shared.summarize(
            transcript: session.transcriptText,
            title: session.title,
            localeHint: localeHint,
            // A voice note in its author's voice (07.11).
            task: .summary(oneVoice: session.isVoiceNote)
        ) else {
            if Summarizer.shared.leavesVoiceNoteQuietly(isVoiceNote: session.isVoiceNote) {
                log.info("End-of-day summary: the provider can't summarize voice note \(session.id, privacy: .public) — left without one")
                VoiceNoteProfile.Declines().record(session.id, provider: Summarizer.shared.providerKind.rawValue)
                return .leftQuietly
            }
            log.error("End-of-day summary failed for \(session.id, privacy: .public)")
            return .failed
        }
        // Templates (backlog 35), without the voice pass this path leaves out
        // (a voice note gets one only picked by hand — `laidOut`).
        let templated = await StoredSessionTemplates.applyWithoutVoice(summary, previous: session.summary, session: session)
        await SessionStore.shared.updateSummary(templated, for: session)
        return .summarized
    }
}
