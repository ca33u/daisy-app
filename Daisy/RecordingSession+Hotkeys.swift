//
//  RecordingSession+Hotkeys.swift
//  Daisy
//
//  Global-hotkey / widget entry points for the three recording
//  modes (meeting toggle, voice-note toggle, dictation
//  push-to-record). Pure code motion out of RecordingSession.swift —
//  the lifecycle itself (start/pause/resume/stop) stays in the main
//  file; these are the thin mode-aware wrappers around it.
//

import Foundation
import os

extension RecordingSession {

    // MARK: - Mark a moment

    /// "This bit matters." Records the current media time, grabs a frame
    /// if one can be had, and writes `markers.json` immediately — see
    /// `MomentMarkers` for why the timestamp is the feature and the
    /// picture is optional.
    ///
    /// Only meaningful while recording. Pressed at any other time it
    /// says so rather than doing nothing: a global hotkey that is silent
    /// when idle is indistinguishable from one that is broken, and this
    /// one will be pressed hopefully, mid-conversation, by someone who
    /// cannot check whether recording is on.
    func markMomentByHotkey() async {
        guard status == .recording || status == .paused else {
            ToastCenter.shared.show(
                String(localized: "Nothing to mark — Daisy isn’t recording."),
                style: .info
            )
            return
        }
        guard let dir = sessionDirectory else {
            log.error("Mark moment: no session directory")
            return
        }

        // Stamp the time BEFORE the capture: SCScreenshotManager can
        // take a few hundred milliseconds, and the moment the user meant
        // is the one they pressed at, not the one we got round to. (The
        // frame's own `index.json` entry is stamped after, so the same
        // picture can read a fraction of a second later in the
        // screenshot gallery than in the marker list. The marker's is
        // the honest one.)
        let offset = max(0, elapsed)
        // A frame only when the user asked for screen capture at all,
        // and only while actually recording — pause is "stop looking at
        // my screen", and it stopped the periodic capture for the same
        // reason. Marking still works in both cases; the timestamp was
        // always the point.
        var frame: String?
        if settings.screenshotsEnabled, status == .recording {
            frame = await screenshots.captureForMarker(
                elapsed: { [weak self] in self?.elapsed ?? 0 },
                into: dir.appendingPathComponent("screenshots", isDirectory: true)
            )
        }

        var markers = MomentMarkerStore.load(from: dir)
        markers.append(MomentMarker(offsetSec: offset, screenshot: frame, createdAt: Date()))
        MomentMarkerStore.write(markers, to: dir)
        momentMarkers = markers

        // Confirm, with the timecode. Deliberately NOT one of the
        // recording sounds — `playStart` mid-meeting reads as "recording
        // just started", which is the one thing it must not say. And
        // deliberately not silent: this is an action the user asked for,
        // aimed at a moment they can no longer see, and the only proof
        // it landed is this line. (The toast budget this spends is the
        // user's own to spend — they pressed a key.)
        let marker = markers.last
        ToastCenter.shared.show(
            String(
                format: String(localized: "Marked at %@"),
                marker?.timecode ?? "0:00"
            ),
            style: .info,
            duration: .seconds(1.4)
        )
        log.info("Moment marked at \(Int(offset), privacy: .public)s (frame: \(frame != nil, privacy: .public), \(markers.count, privacy: .public) total)")
    }

    // MARK: - Hotkey / mode entry points

    /// Convenience for global hotkey / widget tap: start if idle/
    /// finished/failed, pause if recording, resume if paused.
    /// Transitional states (preparing/stopping/summarizing) are
    /// ignored so a hammered hotkey can't interrupt in-flight work.
    /// Note: the hotkey/widget never *fully stops* a session — that
    /// requires the explicit Stop & save action from the popover or
    /// the widget's right-click menu.
    func toggleByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            await start()
        case .recording:
            await pause()
        case .paused:
            await resume()
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Voice-notes — TOGGLE on tap. Single press starts a
    /// `.voiceNote` session (mic only, no system audio, no LLM
    /// summary, kind = note); next press of the same hotkey
    /// stops it. Different from dictation (hold-to-talk) because
    /// voice notes can be longer than the user wants to keep a
    /// finger on the key — meeting yourself, dictating ideas
    /// over 5–10 min, etc.
    func toggleVoiceNoteByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .voiceNote
            // No folder hint: a voice note is now identified by
            // `daisy_kind: note`, not by living in the Notes folder, so it
            // defaults to Inbox like any capture and still lands in the
            // Notes tab (which filters by kind). Was `pendingFolderHint =
            // .notes`, which forced every note into the Notes folder.
            await start()
        case .recording, .paused:
            if currentMode == .voiceNote {
                await stop()
            } else if currentMode == .meeting {
                // Layer a side note over the live meeting instead of
                // refusing: mark a window now, close it on the next
                // press. Finalize splits it into its own Notes session
                // and cuts it from the meeting transcript.
                toggleSideNoteCapture()
            } else {
                ToastCenter.shared.show(
                    String(localized: "Daisy is already recording. Stop the current session first."),
                    style: .warning
                )
            }
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Dictation — push-to-record. Called on hotkey-down edge.
    /// Starts a `.dictation` session (mic only, ephemeral, no
    /// History entry). On release, the transcript is copied to
    /// the clipboard and a toast prompts ⌘V. Wispr-Flow-lite.
    func startDictationHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .dictation
            // Fresh hold, fresh release-flag: a stale one from a
            // previous hold would stop this dictation the instant it
            // started.
            dictationReleasedWhilePreparing = false
            // Claim a screenshot waiting for context NOW, at key-down:
            // the window is about intent ("I pressed this because of that
            // screenshot"), and claiming at release would let a long
            // answer time out mid-sentence. Claiming also closes the
            // window, so the next dictation pastes normally.
            pendingScreenshotNote = ScreenshotNoteCapture.shared.claimPending()
            // Warm the selected fast dictation engine during the hold so
            // release→paste isn't blocked on a cold load.
            switch settings.dictationEngine {
            case .whisper:
                break
            case .parakeet:
                // First-ever use still pays a one-time ~600 MB download.
                Task { await ParakeetEngine.shared.ensureLoaded() }
            case .appleSpeech:
                if #available(macOS 26, *) {
                    let localeID = settings.dictationLocale.isEmpty
                        ? settings.defaultTranscriptionLocale
                        : settings.dictationLocale
                    if localeID != "auto", !localeID.isEmpty {
                        let locale = Locale(identifier: localeID)
                        // Ensures the OS model is installed (background
                        // download on first use); no in-app weight.
                        Task { await AppleSpeechEngine.ensureModelReady(locale: locale) }
                    }
                }
            }
            if settings.dictationUseNemotronLive {
                // Warm the streaming preview engine during the hold so the
                // first partials land within the first chunk (~0.6 s).
                Task { await NemotronLiveEngine.shared.ensureLoaded() }
            }
            await start()
            // The key may have come back up while `start()` was still
            // loading an engine — press and release arrive as two
            // independent tasks, so the release couldn't act on a
            // session that didn't exist yet. Honour it now, before the
            // microphone spends any longer open than the person asked
            // for.
            if dictationReleasedWhilePreparing {
                dictationReleasedWhilePreparing = false
                log.info("Dictation key released while the engine was still loading — stopping the session it just started")
                await stopDictationHotkey()
            }
        case .recording, .paused:
            // The dictation key was pressed from ANOTHER app (that's
            // what the key is for) — an in-window toast is invisible
            // exactly then, and a silently dead key reads as "dictation
            // broke" (field report 2026-08-21: held the key after a
            // screenshot, nothing happened — a meeting was recording).
            // Pill first, toast kept for the in-window case.
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(
                    text: String(localized: "Daisy is already recording. Stop the current session first.")
                ),
                notificationTitle: String(localized: "Daisy is already recording")
            )
            ToastCenter.shared.show(
                String(localized: "Daisy is already recording. Stop the current session first."),
                style: .warning
            )
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Dictation — release. Triggers the stop() path which, when
    /// `currentMode == .dictation`, copies the final transcript
    /// to the clipboard and deletes the session directory before
    /// returning to idle.
    func stopDictationHotkey() async {
        // The press may still be inside `start()`, in which case both
        // guards below would reject this release and leave a microphone
        // open with nobody holding a key. Two shapes of that:
        //
        //   • `.preparing` — the usual one, waiting on a model load
        //     (minutes on a first-ever dictation);
        //   • `.idle` with `pendingMode == .dictation` — `start()` is
        //     awaiting the system microphone prompt, which happens
        //     before it flips to `.preparing`. `pendingMode` is
        //     non-nil only while a start is in flight, so it's a
        //     precise tell rather than a widened net.
        //
        // Record the intent; `startDictationHotkey` acts on it the
        // moment `start()` returns.
        if status == .preparing || pendingMode == .dictation {
            dictationReleasedWhilePreparing = true
            return
        }
        guard currentMode == .dictation else { return }
        guard status == .recording || status == .paused else { return }
        // End-to-end dictation latency: hotkey release → paste. `stop()`
        // runs the whole dictation branch inline (stopCapture → final
        // Whisper pass → DictationPaste.handle → cleanup), so wrapping
        // it measures exactly what the user feels. Same subsystem/
        // category as the finalizePostStop spans so Instruments and
        // `log show --signpost` line up in one lane.
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")
        let releaseState = signposter.beginInterval("dictation_release_to_paste", id: signposter.makeSignpostID())
        let t_release = Date()
        await stop()
        signposter.endInterval("dictation_release_to_paste", releaseState)
        log.info("dictation release→paste: \(Int(Date().timeIntervalSince(t_release) * 1000), privacy: .public)ms")
    }
}
