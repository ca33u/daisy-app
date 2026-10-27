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
        ImprovementStats.record(.momentMarked)

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

    /// A Daisy-key hold during the meeting (backlog 34 K-3): a moment at
    /// the press with what was said over the hold. The span is stored, not
    /// the words — `resolveMomentComments` reads them at Stop and again
    /// after the final pass, and until then `segments` already leaves
    /// them out of the meeting. `from`/`to` are on the recording's clock.
    func markMomentWithComment(offset: Double, frame: String?, from start: Date, to end: Date) -> MomentMarker? {
        guard currentMode == .meeting, status == .recording || status == .paused,
              let dir = sessionDirectory else { return nil }
        var marker = MomentMarker(offsetSec: offset, screenshot: frame, createdAt: Date())
        marker.commentStart = start
        marker.commentEnd = end
        var markers = MomentMarkerStore.load(from: dir)
        markers.append(marker)
        MomentMarkerStore.write(markers, to: dir)
        momentMarkers = markers
        log.info("Moment with a comment at \(Int(offset), privacy: .public)s (frame: \(frame != nil, privacy: .public))")
        return marker
    }

    /// The frame for a Daisy-key moment, when screenshots are on and the
    /// recording isn't paused (the rule `markMomentByHotkey` follows).
    func captureMomentFrame() async -> String? {
        guard currentMode == .meeting, settings.screenshotsEnabled, status == .recording,
              let dir = sessionDirectory else { return nil }
        return await screenshots.captureForMarker(
            elapsed: { [weak self] in self?.elapsed ?? 0 },
            into: dir.appendingPathComponent("screenshots", isDirectory: true)
        )
    }

    /// A Daisy-key command said during the meeting: its span is cut from
    /// the meeting like a comment. On the recording's clock.
    func cutFromMeeting(from start: Date, to end: Date, entryID: UUID) {
        guard currentMode == .meeting else { return }
        daisyCommandSpans.append(DaisyCommandSpan(span: DateInterval(start: start, end: max(start, end)), entryID: entryID))
    }

    /// Turns each commented moment's span into its words, from the lines
    /// the transcribers hold now — live at Stop, full quality after the
    /// final pass. Merged into `markers.json` by marker, so a frame pruned
    /// meanwhile stays pruned.
    func resolveMomentComments() {
        guard momentMarkers.contains(where: { $0.commentStart != nil }), let dir = sessionDirectory else { return }
        let lines = uncutSegments
        var notes: [Date: String?] = [:]
        for marker in momentMarkers where marker.commentStart != nil {
            let words = lines.filter(marker.owns)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            notes[marker.createdAt] = words.isEmpty ? nil : words
        }
        var onDisk = MomentMarkerStore.load(from: dir)
        if onDisk.isEmpty { onDisk = momentMarkers }
        var changed = false
        for index in onDisk.indices {
            guard let note = notes[onDisk[index].createdAt], onDisk[index].note != note else { continue }
            onDisk[index].note = note
            changed = true
        }
        guard changed else { return }
        MomentMarkerStore.write(onDisk, to: dir)
        momentMarkers = onDisk
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
            // The cancelled capture may still be in its start's first wait.
            if isStarting, startingMode == .dictation {
                guard await waitForCancelledDaisyCapture() else { return }
            }
            await start()
        case .recording:
            await pause()
        case .paused:
            await resume()
        case .preparing, .stopping:
            guard currentMode == .dictation, await waitForCancelledDaisyCapture() else { return }
            await start()
        case .summarizing:
            return
        }
    }

    /// ⌃⌥⌘R typed slowly: the Daisy key on ⌃⌥ started a capture and its
    /// cancel is letting the microphone go. The meeting starts once it
    /// has (up to 3 s), rather than the key doing nothing (review 22.10).
    /// False when no Daisy-key cancel is that recent, or it didn't settle.
    private func waitForCancelledDaisyCapture() async -> Bool {
        guard let cancel = DaisyKeyController.shared.lastCancel, Date().timeIntervalSince(cancel) < 2 else { return false }
        func settled() -> Bool {
            if isStarting { return false }
            switch status {
            case .idle, .finished, .failed: return true
            default: return false
            }
        }
        for _ in 0..<60 where !settled() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return settled()
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
                // press. Finalize copies it into its own Notes session
                // (and cuts it from the meeting when side notes are set
                // to cut).
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
    func startDictationHotkey(purpose: DictationPurpose = .paste) async {
        // No readiness gate here. `start()` owns that: it refuses an
        // unfinished onboarding, refuses a model that cannot load, and
        // WAITS for one that merely hasn't loaded yet. A gate at this
        // level that fell through to `start()` without setting
        // `pendingMode` would begin a MEETING recording the moment the
        // model finished loading — which is what 1.0.7.71 shipped, saved
        // only by `start()` refusing everything at the time.
        if let side = sideDictation, side.isDictating || side.pendingMode == .dictation || side.startingMode == .dictation {
            // The dictation key down again while its own start is still
            // waiting for a model: its release was lost (a hold key's
            // key-up can go missing), so this press is the only way left to
            // say «stop» — the start is dropped. Otherwise a repeat press
            // of a key already held.
            if purpose == .paste, side.startingMode == .dictation, side.dictationPurpose == .paste {
                side.requestDictationStartCancel()
            }
            return
        }
        // Another start is already under way on this session (the other
        // of the dictation and Daisy keys, pressed within its wait): this
        // one would overwrite that start's purpose — a Daisy hold pasted,
        // a dictation kept as a note (review 21.10). The first press wins.
        // The dictation key over its own dictation's start cancels it, as
        // above.
        if isStarting || startingMode != nil {
            if purpose == .paste, startingMode == .dictation, dictationPurpose == .paste {
                requestDictationStartCancel()
            }
            return
        }
        // The previous recording is still being finished (final pass,
        // summary). Starting here would reset this session and cancel
        // that; the dictation goes to a session of its own instead.
        if summaryTask != nil, !isDictationSidecar {
            switch status {
            case .idle, .finished, .failed, .summarizing:
                let side = sideDictation ?? RecordingSession(settings: settings, isDictationSidecar: true)
                sideDictation = side
                log.info("Dictation while the previous recording is still finishing — dictating on a side session")
                await side.startDictationHotkey(purpose: purpose)
                return
            case .preparing, .recording, .paused, .stopping:
                break
            }
        }
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .dictation
            dictationPurpose = purpose
            // Fresh hold, fresh release-flag: a stale one from a
            // previous hold would stop this dictation the instant it
            // started.
            dictationReleasedWhilePreparing = false
            // Claim a screenshot waiting for context NOW, at key-down:
            // the window is about intent ("I pressed this because of that
            // screenshot"), and claiming at release would let a long
            // answer time out mid-sentence. Claiming also closes the
            // window, so the next dictation pastes normally.
            // Since K-3 the Daisy key's hold answers a screenshot; the
            // dictation key pastes and says which key does (unless there's
            // no Daisy key to hold — then dictation still answers).
            if purpose == .paste, !ScreenshotNoteCapture.shared.dictationClaims {
                pendingScreenshotNote = nil
                ScreenshotNoteCapture.shared.pointToDaisyKey()
            } else {
                pendingScreenshotNote = ScreenshotNoteCapture.shared.claimPending()
            }
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
                // The same key's release: a Daisy press stops its own
                // capture, a dictation key an ordinary one.
                let token: UUID? = {
                    switch dictationPurpose {
                    case .daisyKeyHold(let t), .daisyKeyTap(let t): return t
                    case .paste: return nil
                    }
                }()
                await stopDictationHotkey(daisyKeyToken: token)
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

    /// The Daisy key came back up within a tap: the capture its key-down
    /// started is thrown away when it finishes, and the long note starts.
    /// Marked on whichever session is capturing — this one, or the side
    /// dictation while the previous recording finishes.
    func markDaisyKeyTap(_ token: UUID) {
        // Only the capture this press started — never an ordinary
        // dictation that happens to be running.
        if let side = sideDictation, side.dictationPurpose == .daisyKeyHold(token) {
            side.dictationPurpose = .daisyKeyTap(token)
        } else if dictationPurpose == .daisyKeyHold(token) {
            dictationPurpose = .daisyKeyTap(token)
        }
    }

    /// Dictation — release. Triggers the stop() path which, when
    /// `currentMode == .dictation`, copies the final transcript
    /// to the clipboard and deletes the session directory before
    /// returning to idle.
    /// Whether the capture running here is the one a release is for: the
    /// dictation key's (no token) stops only an ordinary dictation, the
    /// Daisy key's only its own press's — so one key let go never ends
    /// the other's capture (review 21.10).
    func ownsDictationCapture(_ token: UUID?) -> Bool {
        guard let token else { return dictationPurpose == .paste }
        return dictationPurpose == .daisyKeyHold(token) || dictationPurpose == .daisyKeyTap(token)
    }

    func stopDictationHotkey(daisyKeyToken token: UUID? = nil) async {
        // The press may still be inside `start()`, in which case both
        // guards below would reject this release and leave a microphone
        // open with nobody holding a key. Two shapes of that:
        //
        //   • `.preparing` — the usual one, waiting on a model load
        //     (minutes on a first-ever dictation);
        //   • `.idle` with `pendingMode == .dictation` — the press is
        //     queued and `start()` hasn't taken it yet; or, once it
        //     has (19.10: it takes its intent before its first wait —
        //     a stored-audio job yielding, the system microphone
        //     prompt), `startingMode == .dictation` until `.preparing`.
        //     Both are non-nil only while a start is in flight, so
        //     it's a precise tell rather than a widened net.
        //
        // Since 27.10 this cancels the start: a model wait ends now and
        // the microphone never opens (`requestDictationStartCancel`).
        if let side = sideDictation, side.isDictating || side.pendingMode == .dictation || side.startingMode == .dictation,
           side.ownsDictationCapture(token) {
            await side.stopDictationHotkey(daisyKeyToken: token)
            return
        }
        guard ownsDictationCapture(token) else { return }
        if status == .preparing || pendingMode == .dictation || startingMode == .dictation {
            requestDictationStartCancel()
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
