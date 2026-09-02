//
//  SilenceMonitor.swift
//  Daisy
//
//  Detects long stretches of silence during a recording and asks
//  whether the user just forgot to hit Stop. Owned by
//  RecordingSession; surfaces the prompt as a native
//  `UNUserNotification` (see `SilencePromptNotification`) — the
//  custom SwiftUI bubble that used to live next to the daisy widget
//  was retired 2026-05-18 after several rounds of positioning-maths
//  pain that the OS-supplied banner handles for free.
//
//  Heuristic:
//   • Speech signal: arrival of a new TranscriptSegment with
//     non-empty text. We deliberately do NOT key off raw mic levelDB
//     because keyboard typing, HVAC, water running, and street noise
//     all clear the threshold without WhisperKit producing any text.
//     The transcriber's output is the cleanest "the user is actually
//     speaking" signal we have.
//   • Silence window: 3 minutes since the most recent transcribed
//     segment during `.recording` triggers the prompt. Pausing the
//     session, hitting Stop, or any new transcript content resets
//     the clock.
//   • Snooze: if the user dismisses with "Not yet", we don't poke
//     again for another full window. Stop / Pause / Resume also
//     resets the snooze so a fresh recording session starts clean.
//   • Long pause: when the session sits on `.paused` for more than
//     5 minutes we also surface the prompt. Pause is intentional
//     (the user pressed it) but "I'll be back in two minutes"
//     turns into "I forgot I left it on" with surprising frequency,
//     and a paused recording quietly draining battery is exactly the
//     failure mode the prompt exists to catch.
//
//  Action routing: the banner's Stop & save / Not yet buttons hit
//  `DaisyAppDelegate.userNotificationCenter(_:didReceive:)`, which
//  posts to `NotificationCenter.default` on a Daisy-private name.
//  The active SilenceMonitor subscribes on `start()` and routes
//  back into `session.stop()` or `snooze()`.
//
//  Numbers are intentionally not user-configurable for v1 — easier
//  to ship a sensible default than a settings tab nobody touches.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class SilenceMonitor {
    @ObservationIgnored
    private weak var session: RecordingSession?
    @ObservationIgnored
    private var tickTask: Task<Void, Never>?
    @ObservationIgnored
    private var pausedPromptTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastSpeechAt: Date?
    @ObservationIgnored
    private var snoozedUntil: Date?
    @ObservationIgnored
    private var promptOutstanding: Bool = false
    @ObservationIgnored
    private var stopObserver: NSObjectProtocol?
    @ObservationIgnored
    private var snoozeObserver: NSObjectProtocol?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SilenceMonitor")

    private let silenceWindowSec: TimeInterval = 3 * 60

    /// Above this RMS the microphone is hearing something with content —
    /// speech, typing, a room with people in it. Only used in the
    /// Live-transcript-Off tier, where there is no transcript to read.
    ///
    /// −60, not −50: the recorder's own notes put a live mic at about
    /// −55 dB RMS and a quiet room at −70…−90, so −50 would have called
    /// a softly-spoken or distant participant "silence" and offered to
    /// stop their meeting. −60 still clears room tone by 10–30 dB
    /// (review find, 2026-09-02).
    private static let audibleMicFloorDB: Float = -60
    private let pausedWindowSec:  TimeInterval = 5 * 60
    private let pollIntervalSec:  TimeInterval = 5

    init(session: RecordingSession) {
        self.session = session
    }

    deinit {
        tickTask?.cancel()
        pausedPromptTask?.cancel()
        // Capture observer tokens into a local array first so the
        // deinit closure doesn't need to capture `self` (which is
        // already being torn down). NotificationCenter handles
        // removal with no actor isolation requirements.
        let stop = stopObserver
        let snooze = snoozeObserver
        let center = NotificationCenter.default
        if let stop { center.removeObserver(stop) }
        if let snooze { center.removeObserver(snooze) }
    }

    // MARK: - Lifecycle hooks called from RecordingSession

    /// Begin monitoring. Called when the session enters `.recording`.
    /// Idempotent.
    func start() {
        if tickTask != nil { return }
        lastSpeechAt = Date()
        promptOutstanding = false
        snoozedUntil = nil
        subscribeToBannerActions()
        tickTask = Task { [weak self] in
            await self?.runLoop()
        }
        log.info("Silence monitor armed")
    }

    /// Pause monitoring without resetting state. Replaces the
    /// speech-poll loop with a single-shot pause-prompt timer.
    func pause() {
        tickTask?.cancel()
        tickTask = nil
        SilencePromptNotification.cancel()
        promptOutstanding = false
        armPausedTimer()
    }

    /// Resume monitoring after `pause()`. Re-arms the clock from "now".
    func resume() {
        cancelPausedTimer()
        SilencePromptNotification.cancel()
        promptOutstanding = false
        guard tickTask == nil else { return }
        lastSpeechAt = Date()
        tickTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Tear down completely. Called on session stop / reset / failed.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        cancelPausedTimer()
        SilencePromptNotification.cancel()
        promptOutstanding = false
        lastSpeechAt = nil
        snoozedUntil = nil
        unsubscribeFromBannerActions()
    }

    /// User dismissed the banner with "Not yet" — give them a fresh
    /// silence window before nagging again. Works for both the
    /// recording-silence prompt and the long-pause prompt.
    func snooze() {
        SilencePromptNotification.cancel()
        promptOutstanding = false
        snoozedUntil = Date().addingTimeInterval(silenceWindowSec)
        lastSpeechAt = Date()
        if tickTask == nil, session?.status == .paused {
            armPausedTimer()
        }
    }

    /// User explicitly hit "Stop & save" via the banner — close it
    /// out, the session is being finalised anyway. Stop is dispatched
    /// from the action handler; this method just clears state.
    func acknowledge() {
        SilencePromptNotification.cancel()
        promptOutstanding = false
        cancelPausedTimer()
    }

    // MARK: - Banner actions (NotificationCenter bus)

    private func subscribeToBannerActions() {
        unsubscribeFromBannerActions()
        let center = NotificationCenter.default
        stopObserver = center.addObserver(
            forName: SilencePromptNotification.stopRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.acknowledge()
                if let session = self.session {
                    await session.stop()
                }
            }
        }
        snoozeObserver = center.addObserver(
            forName: SilencePromptNotification.snoozeRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.snooze()
            }
        }
    }

    private func unsubscribeFromBannerActions() {
        let center = NotificationCenter.default
        if let stopObserver { center.removeObserver(stopObserver) }
        if let snoozeObserver { center.removeObserver(snoozeObserver) }
        stopObserver = nil
        snoozeObserver = nil
    }

    // MARK: - Internals

    /// Schedule a one-shot prompt for the long-pause case. Cancelled
    /// by `resume()`, `stop()`, or re-armed by `snooze()`.
    private func armPausedTimer() {
        cancelPausedTimer()
        let window = pausedWindowSec
        pausedPromptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self else { return }
            guard
                let session = self.session,
                session.status == .paused,
                !self.promptOutstanding
            else { return }
            // User opted out of prompts in Settings — still mark
            // promptOutstanding so we don't repeat-fire, but skip
            // the banner itself.
            guard session.settings.silencePromptsEnabled else { return }
            self.promptOutstanding = true
            self.log.info("Silence prompt shown after \(Int(window), privacy: .public)s on pause")
            SilencePromptNotification.post()
        }
    }

    private func cancelPausedTimer() {
        pausedPromptTask?.cancel()
        pausedPromptTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pollIntervalSec))
            if Task.isCancelled { break }
            tick()
        }
    }

    private func tick() {
        guard let session, session.status == .recording else { return }

        // New transcript text is the primary sign of life — but it isn't
        // the only one, and in one configuration it never arrives at
        // all. With Live transcript = Off no segments are produced
        // during the recording (the whole point of the tier: one pass on
        // Stop), so `lastSpeechAt` never moved and every meeting got
        // "seems to be over — Stop & save?" three minutes in, no matter
        // how loud the room. One click on that banner stops a meeting
        // mid-sentence (audit 2026-09-01).
        //
        // Audio levels are the fallback, the same signal auto-stop
        // already uses: the mic RMS floor distinguishes speech from a
        // room tone, and the system stream stamps its own last audible
        // sample.
        if session.micTranscriber.liveTierIsOff {
            let micIsLive = session.recorder.lastMicRMSDB > Self.audibleMicFloorDB
            let systemHeardRecently = session.systemAudio.lastAudibleSampleAt
                .map { Date().timeIntervalSince($0) < silenceWindowSec } ?? false
            if micIsLive || systemHeardRecently {
                lastSpeechAt = Date()
                if promptOutstanding {
                    SilencePromptNotification.cancel()
                    promptOutstanding = false
                }
                return
            }
        }

        let latestSpeechAt = session.segments
            .reversed()
            .first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })?
            .startedAt

        if let latestSpeechAt, latestSpeechAt > (lastSpeechAt ?? .distantPast) {
            lastSpeechAt = latestSpeechAt
            if promptOutstanding {
                SilencePromptNotification.cancel()
                promptOutstanding = false
            }
            return
        }

        if let snoozedUntil, Date() < snoozedUntil {
            return
        }

        let referenceDate = lastSpeechAt ?? Date()
        let quietFor = Date().timeIntervalSince(referenceDate)
        if quietFor >= silenceWindowSec, !promptOutstanding {
            // Respect the user's Settings → Notifications toggle.
            // We keep tick'ing internally either way so timing
            // metrics stay consistent; we just don't post.
            guard session.settings.silencePromptsEnabled else { return }
            promptOutstanding = true
            log.info("Silence prompt shown after \(Int(quietFor), privacy: .public)s without new transcript")
            SilencePromptNotification.post()
        }
    }
}
