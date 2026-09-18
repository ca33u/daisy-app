//
//  RecordingSession+AutoStop.swift
//  Daisy
//
//  Calendar-bound end-of-meeting ask: the silence-gated evaluator
//  that ASKS to stop («Stop & save?» widget bubble) once the bound
//  meeting has ended and the room has gone quiet (or at a hard
//  overrun backstop) — Daisy never stops on its own since 2026-08-21
//  — plus the manual-start
//  fallback that binds a hotkey-started session to a currently
//  running calendar event so auto-stop still arms. Pure code motion
//  out of RecordingSession.swift — timers and latch flags stay as
//  stored properties on the class.
//

import Foundation
import os

extension RecordingSession {
    // MARK: - Auto-stop (calendar-bound)

    /// Once past endDate+grace, stop only after this much continuous quiet
    /// on BOTH mic and system. A live conversation never has this long a
    /// gap; a finished meeting does.
    private static let autoStopSilenceToStopSec: TimeInterval = 120
    /// BEFORE the scheduled end, stop only after this much continuous
    /// quiet — the "everyone left early" case. Tester report (1.0.7.18):
    /// stopped talking ~30 min before the meeting's scheduled end and
    /// the recording ran the full remainder, because the quiet gate
    /// only armed past endDate+grace. Ten minutes of TOTAL silence
    /// (mic AND system below the floor) mid-meeting is dead air, not a
    /// pause — and the 30 s "Keep going" toast still covers the rare
    /// silent-work-session case.
    private static let autoStopPreEndSilenceSec: TimeInterval = 600
    /// Absolute backstop: stop unconditionally this long past the scheduled
    /// end even if audio is still flowing (background music, forgotten
    /// call), so a left-running session can't record forever.
    private static let autoStopMaxOverrunSec: TimeInterval = 30 * 60
    /// RMS-dBFS floor above which the MIC counts as "audible" for
    /// auto-stop gating. RMS, not peak: the original peak>-55 gate
    /// (1.0.7.18) spiked on keyboard clicks / chair creaks / fans,
    /// each sampling instant above the floor reset the silence clock,
    /// and a tester's ended meeting recorded all the way to the
    /// 30-min backstop. Conversational speech RMS sits ≳ −45;
    /// room tone ≲ −55.
    private static let autoStopMicRMSFloorDB: Float = -50
    /// How recently the SYSTEM side must have delivered an audible
    /// buffer (peak > its −55 floor) to count as "someone talking".
    /// Timestamp-based on purpose: ScreenCaptureKit stops delivering
    /// buffers when the call app goes quiet or quits, so the published
    /// `peakLevelDB` FREEZES at its last (loud) value — comparing it
    /// to a floor kept `audible` true for an entire post-meeting
    /// half-hour (same tester report).
    private static let autoStopSystemRecencySec: TimeInterval = 15
    /// How often the silence-gated evaluator re-checks.
    private static let autoStopEvalIntervalSec: TimeInterval = 10

    /// Schedule the auto-stop fire + 30s warning toast if the
    /// session is bound to a calendar event AND the user has the
    /// auto-stop preference on. No-op otherwise (manual sessions are
    /// never auto-stopped).
    // internal for RecordingSession.swift (called from start()/resume())
    func scheduleAutoStopIfNeeded() {
        cancelAutoStop()
        autoStopSuppressed = false
        autoStopWarned = false
        guard settings.autoStopFromCalendar else {
            autoStopLog.info("scheduleAutoStop: skipped — autoStopFromCalendar=false")
            return
        }
        guard let meeting = boundMeeting else {
            // Most common silent failure pre-1.0.4: user toggled the
            // pref ON but started the recording manually (hotkey /
            // widget) before the calendar tick auto-started it, so
            // boundMeeting was never wired. `start()` now tries to
            // auto-bind via `bindCurrentMeetingIfPossible()`; this
            // log captures the case where even that fallback misses.
            autoStopLog.info("scheduleAutoStop: skipped — no boundMeeting on this session (manual start without matching calendar event in fire window)")
            return
        }
        let now = Date()
        let hardMax = meeting.endDate.addingTimeInterval(Self.autoStopMaxOverrunSec)
        guard hardMax > now else {
            autoStopLog.warning("scheduleAutoStop: meeting '\(meeting.title, privacy: .private)' already past end+maxOverrun (endDate=\(meeting.endDate.description, privacy: .public)) — no timer armed")
            return
        }

        // Silence-gated auto-stop (replaces the old fixed endDate+grace
        // one-shot that cut people off mid-sentence — Egor, 2026-06-01:
        // "стопнул, хотя мы ещё разговаривали"). A repeating evaluator
        // stops only once there's been `autoStopSilenceToStopSec` of quiet
        // past endDate+grace, or unconditionally at endDate+maxOverrun.
        // See evaluateAutoStop().
        autoStopLastAudibleAt = now
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoStopEvalIntervalSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluateAutoStop() }
        }
        autoStopLog.notice("Auto-stop armed (silence-gated) for '\(meeting.title, privacy: .private)': earliest endDate+\(self.settings.autoStopGraceSec, privacy: .public)s then \(Int(Self.autoStopSilenceToStopSec), privacy: .public)s quiet; hard max endDate+\(Int(Self.autoStopMaxOverrunSec), privacy: .public)s")
    }

    /// Try to auto-bind a calendar meeting to the current session
    /// when the user started recording manually (hotkey/widget) but
    /// a calendar event is currently in or near its start window.
    /// Mirrors the `CalendarService.tick()` fire window — `meeting.start
    /// - 30s … meeting.end` — so any meeting we'd have auto-started is
    /// also a meeting we'll auto-bind to. Without this, the tester's
    /// hotkey-start-before-calendar-tick path produced an unbindable
    /// session and silently swallowed the auto-stop preference.
    ///
    /// Idempotent — no-op if `boundMeeting` is already set or no
    /// matching meeting exists. Called from `start()` after `reset()`
    /// has applied any explicit `pendingBoundMeeting`.
    // internal for RecordingSession.swift (called from start()/resume())
    func bindCurrentMeetingIfPossible() {
        guard boundMeeting == nil else { return }
        guard currentMode == .meeting else { return }
        let now = Date()
        let match = CalendarService.shared.upcomingMeetings.first { meeting in
            // Window mirrors CalendarService.tick(): -120s … +30s of
            // start, AND not yet past end. Without the lower bound a
            // long-running all-day "OOO" event flagged as a meeting
            // would bind anything started in the last 8 hours — and
            // auto-stop would fire at the event's far-future end.
            let deltaToStart = meeting.startDate.timeIntervalSince(now)
            let inStartWindow = deltaToStart <= 30 && deltaToStart >= -120
            let stillRunning = meeting.endDate > now
            return inStartWindow && stillRunning
        }
        guard let meeting = match else {
            autoStopLog.info("bindCurrentMeetingIfPossible: no calendar meeting in fire window")
            return
        }
        boundMeeting = meeting
        // Only overwrite the autogenerated `"Meeting yyyy-MM-dd HH:mm"`
        // placeholder (set at line ~577), never a user-typed title.
        // hasPrefix("Meeting ") was too greedy — caught "Meeting with
        // Anna prep" and clobbered intentional user titles.
        if title.isEmpty || Self.isAutoGeneratedMeetingTitle(title) {
            title = meeting.title
        }
        if folder == .inbox {
            folder = FolderStore.shared.existingFolder(slug: settings.defaultMeetingFolderSlug) ?? .inbox
        }
        // Pre-fill tag from attendee domain (most-frequent
        // external org). Same call site as the auto-binding in
        // start() so manual-start sessions also get the suggestion.
        if tag.isEmpty, let suggested = TagSuggestion.suggest(from: meeting.attendeeEmails) {
            tag = suggested
        }
        autoStopLog.info("bindCurrentMeetingIfPossible: auto-bound to '\(meeting.title, privacy: .private)' (started \(Int(now.timeIntervalSince(meeting.startDate)), privacy: .public)s ago, ends in \(Int(meeting.endDate.timeIntervalSince(now)), privacy: .public)s)")
    }

    /// True iff `s` matches the exact `"Meeting yyyy-MM-dd HH:mm"`
    /// shape produced by `start()` when the user hasn't typed one in.
    /// Uses a precise regex rather than `hasPrefix("Meeting ")` so
    /// a user-typed title that happens to start with "Meeting " is
    /// preserved through auto-bind.
    nonisolated private static func isAutoGeneratedMeetingTitle(_ s: String) -> Bool {
        let pattern = #"^Meeting \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    // internal for RecordingSession.swift (called from stop()/reset()/failFast())
    func cancelAutoStop() {
        autoStopTimer?.invalidate()
        autoStopWarningTimer?.invalidate()
        autoStopTimer = nil
        autoStopWarningTimer = nil
        // Prompt-mode leftovers: a pending snooze dies with the
        // evaluator (covers stop/reset/failFast AND the fresh re-arm
        // at the top of scheduleAutoStopIfNeeded), and any
        // still-visible "Meeting seems over?" banner is moot once
        // auto-stop is disarmed.
        autoStopSnoozeUntil = nil
        AutoStopPromptNotification.cancel()
        WidgetBubbleCenter.shared.dismiss(tag: Self.autoStopAskBubbleTag)
    }

    /// Repeating evaluator (every `autoStopEvalIntervalSec`) for the
    /// silence-gated auto-stop. Stops the session only once it's been
    /// quiet for `autoStopSilenceToStopSec` past endDate+grace, or
    /// unconditionally at endDate+maxOverrun. While anyone is still
    /// talking (mic OR system above the floor), the stop is deferred.
    private func evaluateAutoStop() {
        guard status == .recording || status == .paused, !autoStopSuppressed else {
            cancelAutoStop()
            return
        }
        guard let meeting = boundMeeting else { cancelAutoStop(); return }
        let now = Date()

        // Prompt-mode snooze ("10 / 30 more minutes" on the banner):
        // park the whole evaluator until the deadline, then resume
        // with a clean warned-latch so the question can be asked
        // again. If the conversation resumed during the snooze, the
        // first post-expiry tick sees live audio and simply defers.
        if let until = autoStopSnoozeUntil {
            if now < until {
                return
            } else {
                autoStopSnoozeUntil = nil
                autoStopWarned = false
                autoStopLog.info("Auto-stop snooze expired — re-evaluating")
            }
        }

        let earliest = meeting.endDate.addingTimeInterval(TimeInterval(settings.autoStopGraceSec))
        let hardMax = meeting.endDate.addingTimeInterval(Self.autoStopMaxOverrunSec)

        // Is anyone still talking? Mic: live RMS (transient-proof).
        // System: recency of the last audible BUFFER, not the
        // published peak — see the constants above for why both
        // replaced the old `peak > -55` checks.
        let micAudible = recorder.lastMicRMSDB > Self.autoStopMicRMSFloorDB
        let sysAudible: Bool = {
            guard let at = systemAudio.lastAudibleSampleAt else { return false }
            return now.timeIntervalSince(at) < Self.autoStopSystemRecencySec
        }()
        let audible = micAudible || sysAudible
        autoStopLog.debug("eval: micRMS=\(Int(self.recorder.lastMicRMSDB), privacy: .public)dB sysAudible=\(sysAudible, privacy: .public) silentFor=\(Int(now.timeIntervalSince(self.autoStopLastAudibleAt ?? now)), privacy: .public)s")

        // Absolute backstop — even here Daisy no longer stops on its
        // own (2026-08-21, Egor: «не будет авто стопа — просто спросим
        // в бабле»). One ask at the overrun mark; an ignored ask keeps
        // recording. The trade-off is deliberate: a forgotten session
        // can now run indefinitely, in exchange for never cutting a
        // live conversation.
        if now >= hardMax {
            if !autoStopWarned {
                presentAutoStopPrompt(silence: false)
            }
            return
        }

        if audible {
            autoStopLastAudibleAt = now
            // Conversation resumed while the ask was up (or after it
            // was ignored) — the question is moot. Withdraw both
            // surfaces and unlatch so it can be asked again when the
            // room next goes quiet.
            if autoStopWarned {
                autoStopWarned = false
                AutoStopPromptNotification.cancel()
                WidgetBubbleCenter.shared.dismiss(tag: Self.autoStopAskBubbleTag)
                autoStopLog.info("Auto-stop ask: audio resumed — question withdrawn")
            }
            return
        }

        // Quiet on the channels we can hear — but can we hear the other
        // side at all? A loopback stream that died (display asleep, lid
        // shut — tester log 2026-09-16: `sys=empty`, stream dead after
        // 25 s) makes "quiet" mean "the person is listening", and the
        // pill fired in the middle of their call. With the far side
        // unknown, don't guess: only the hard overrun above asks.
        // `.stopped` specifically: a capture that never started (Screen
        // Recording denied → mic-only by preflight) leaves the state at
        // `.idle`, and there the mic is the honest, only channel.
        if currentMode == .meeting, settings.captureSystemAudio, systemAudio.state == .stopped {
            autoStopLastAudibleAt = now
            autoStopLog.debug("eval: far side not captured (\(String(describing: self.systemAudio.state), privacy: .public)) — silence ask suppressed")
            return
        }

        // Silent right now. Two quiet thresholds:
        //   past endDate+grace → 120 s (meeting is over, wrap up fast)
        //   before endDate     → 10 min (everyone left early; long
        //                        enough that a real meeting pause
        //                        never trips it)
        // `autoStopLastAudibleAt` is seeded at arm time, so `?? now`
        // is just belt-and-braces (treats unknown as "audible now").
        let silentFor = now.timeIntervalSince(autoStopLastAudibleAt ?? now)
        let threshold = now >= earliest
            ? Self.autoStopSilenceToStopSec
            : Self.autoStopPreEndSilenceSec
        if silentFor >= threshold, !autoStopWarned {
            presentAutoStopPrompt(silence: true, beforeScheduledEnd: now < earliest)
        }
    }

    /// The confirmed stop — only ever reached from the user's own
    /// answer to the ask (bubble tap / banner action / toast button).
    /// Daisy never calls this on a timer anymore (2026-08-21), so the
    /// "recording saved" banner is gone with the auto-stop: the person
    /// who tapped Stop & save watched it happen.
    private func performAutoStop() async {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        autoStopLog.notice("Auto-stop performing stop() — user confirmed the end-of-meeting ask; the SESSION SUMMARY that follows is this one")
        ToastCenter.shared.show(String(localized: "Meeting ended — stopping & saving."), style: .info, duration: .seconds(2))
        // A next meeting waiting behind this ask starts right after the
        // stop — same as the old silent rotation, including its one
        // trade-off: the final pass for THIS session is skipped, because
        // issue #7 showed that cancelling it after the fact kills the
        // new session's transcription instead. The live transcript is
        // on disk; the archive stays, so a re-transcribe recovers the
        // full-quality pass later.
        if hasPendingLiveCalendarMeeting { skipFinalPassOnNextStop = true }
        await stop()
        await startPendingCalendarMeetingIfLive()
    }

    // MARK: - The end-of-meeting ask

    /// Stable bubble tag so the withdrawal paths (audio resumed,
    /// cancelAutoStop) only ever tear down their own pill.
    static let autoStopAskBubbleTag = "autostop-ask"

    /// The one end-of-meeting surface (2026-08-21): a widget-bubble
    /// «Stop & save?» — tap the pill to stop & save, ✕ or the countdown
    /// to keep recording. Daisy NEVER stops on its own anymore; every
    /// timing gate (post-end quiet, early-wrap quiet, hard overrun)
    /// funnels into this one question, and an ignored question just
    /// keeps recording. Falls back to the actionable macOS banner
    /// (Stop & save / snooze) + action toast only when no bubble host
    /// exists.
    private func presentAutoStopPrompt(silence: Bool, beforeScheduledEnd: Bool = false) {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        guard !autoStopWarned else { return }
        autoStopWarned = true
        // Keep the quiet clock honest at ask time (a snooze can expire
        // with a stale autoStopLastAudibleAt).
        autoStopLastAudibleAt = Date()
        let shown = WidgetBubbleCenter.shared.show(WidgetBubbleContent(
            text: String(localized: "Stop & save?"),
            actionTitle: String(localized: "Stop & save"),
            actionSymbol: "stop.circle",
            tag: Self.autoStopAskBubbleTag,
            action: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.performAutoStopFromPrompt()
                }
            }
        ))
        if !shown {
            let msg: String
            if silence && beforeScheduledEnd {
                msg = String(localized: "Meeting's been silent for 10 minutes — looks like it wrapped up early. Stop & save?")
            } else if silence {
                msg = String(localized: "Meeting seems over — it's been quiet for a couple of minutes. Stop & save?")
            } else {
                msg = String(localized: "Meeting has run well past its end. Stop & save?")
            }
            AutoStopPromptNotification.post(meetingTitle: boundMeeting?.title ?? title)
            // In-app twin of the banner (and the whole ask when macOS
            // notifications are denied). One action only — the snooze
            // options live on the banner; ignoring the toast just keeps
            // recording.
            ToastCenter.shared.showAction(
                msg,
                actionLabel: "Stop & save",
                style: .warning,
                duration: .seconds(15)
            ) { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.performAutoStopFromPrompt() }
            }
        }
        let micRMS = Int(recorder.lastMicRMSDB)
        let sysAgo = systemAudio.lastAudibleSampleAt.map { Int(Date().timeIntervalSince($0)) }
        autoStopLog.notice("Auto-stop ASK presented (surface=\(shown ? "bubble" : "banner+toast", privacy: .public) silence=\(silence, privacy: .public) beforeScheduledEnd=\(beforeScheduledEnd, privacy: .public)) micRMS=\(micRMS, privacy: .public)dB sysAudibleAgo=\(sysAgo.map { "\($0)s" } ?? "never", privacy: .public) — waiting for the user")
    }

    /// "10 / 30 more minutes" on the auto-stop prompt. Parks the
    /// evaluator until the deadline, un-latches `autoStopWarned` so
    /// the question can be asked again afterwards, and withdraws the
    /// banner.
    // internal for RecordingSession.swift (called from the init-time
    // Foundation-bus observers for the banner's snooze actions)
    func snoozeAutoStop(minutes: Int) {
        guard status == .recording || status == .paused else { return }
        autoStopSnoozeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        autoStopWarned = false
        AutoStopPromptNotification.cancel()
        ToastCenter.shared.show(String(localized: "Auto-stop snoozed for \(minutes) minutes."), style: .info)
        autoStopLog.info("Auto-stop snoozed for \(minutes, privacy: .public) min by prompt action")
    }

    /// "Stop & save" on the auto-stop prompt (banner action or the
    /// in-app toast button) — same stop path the silence-gated flow
    /// uses, after withdrawing the banner.
    // internal for RecordingSession.swift (called from the init-time
    // Foundation-bus observer for the banner's Stop & save action)
    func performAutoStopFromPrompt() async {
        guard status == .recording || status == .paused else { return }
        AutoStopPromptNotification.cancel()
        autoStopLog.info("Auto-stop prompt: user confirmed Stop & save")
        await performAutoStop()
    }
}
