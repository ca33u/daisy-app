//
//  RecordingSession+Dictation.swift
//  Daisy
//
//  Post-Stop handling for DICTATION mode, lifted out of the giant `stop()`
//  in RecordingSession.swift (architecture cleanup — behaviour unchanged).
//  Dictation is fully ephemeral: transcribe the held mic buffer (fast
//  engine → Whisper fallback), apply the user's vocabulary, record usage,
//  paste, and tear the session down. Nothing is saved to Library, and
//  nothing leaves the machine.
//

import Foundation
import os

extension RecordingSession {
    /// Finalize a `.dictation` session and paste the result. `durSec` is
    /// the recorded length (passed from `stop()`, which already computed
    /// it). Runs INLINE on Stop — the paste waits on it — so every step is
    /// latency-conscious: lite decode, and nothing that leaves the machine.
    ///
    /// There used to be an optional "rewrite in my voice" LLM pass here,
    /// between recognition and paste. Removed 2026-09-12: it cost ~7.5 s
    /// against an 8 s deadline on every dictation and sent each one to
    /// the cloud provider, in a feature whose whole value is that the
    /// text appears the instant you let go of the key. It was also
    /// circular — the voice profile is learned from dictations, so
    /// applying it back to a dictation was an expensive identity. Styling
    /// belongs on text that is NOT already in the person's voice: a
    /// follow-up (`FollowUpVoice`) or whatever they select and hit the
    /// rewrite hotkey on (`SelectionRewrite`). Both still exist.
    func finishDictation(durSec: Int) async {
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "Dictation")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        let transcriptText: String
        let samples = micTranscriber.capturedSamples

        // The Daisy key (backlog 34): a tap throws its half-second away
        // and fixes the layout — before any engine runs on it; a hold
        // hands its words over instead of pasting them. Read once and
        // reset, so a later ordinary dictation on this session pastes.
        let purpose = dictationPurpose
        dictationPurpose = .paste
        if case .daisyKeyTap(let token) = purpose {
            // A screenshot waiting for context isn't answered by a tap:
            // its window comes back whole.
            if let pending = pendingScreenshotNote {
                pendingScreenshotNote = nil
                ScreenshotNoteCapture.shared.restorePending(pending)
            }
            log.info("Daisy key tap — capture discarded, fixing the layout")
            if let dir = sessionDirectory { try? FileManager.default.removeItem(at: dir) }
            releaseSessionsFolderTicket()
            reset()
            DaisyKeyController.shared.tapCaptureFinished(token: token, on: self)
            return
        }
        let isDaisyHold: Bool = { if case .daisyKeyHold = purpose { return true }; return false }()
        // The flower turned at the key-up; a hold that ends here without
        // reaching the controller (a screenshot's context, a discarded
        // note) must not leave it turning.
        defer { if isDaisyHold { DaisyKeyIndicator.shared.settle() } }

        // Fast-engine attempt (Parakeet or Apple SpeechAnalyzer) — both
        // transcribe the captured mic buffer directly, skipping the Whisper
        // final pass. Any miss (off, error, empty, or — for Apple — pre-26 /
        // "auto" locale / model not yet installed) drops through to Whisper.
        // Every fast-engine miss is LOGGED with its reason (2026-07-25):
        // the silent `try?`-and-fall-through made field logs useless —
        // an "Apple" dictation that quietly took the Whisper path left
        // no trace of why, so engine bugs looked identical to user
        // error. The fallback policy itself is unchanged and uniform:
        // fast engine produces text, or logs why not and Whisper takes
        // over.
        var fastText: String? = nil
        // The fast engine threw (as opposed to hearing nothing): the one
        // miss worth telling the person about when Whisper can't stand in.
        var fastEngineFailed = false
        // Silero heard no speech in the whole hold (Parakeet's silence
        // trim): an empty dictation without asking any engine.
        var vadHeardNoSpeech = false
        // A clip too short to be speech: Parakeet throws on anything under
        // ~0.3 s (FluidAudio's floor), and a tap is not a failure to report.
        let longEnoughToBeSpeech = samples.count >= 4_800
        switch settings.dictationEngine {
        case .whisper:
            break
        case .parakeet:
            // `transcribe` awaits `ensureLoaded` internally, so on a
            // first-ever use it would hold this RELEASE for the whole
            // ~600 MB download the hotkey handler just kicked off. Not
            // this time: the download keeps going in the background and
            // Whisper takes this one. (`start()` already waited for a
            // cached model to load, so the common case reaches here
            // `.ready`.)
            let parakeetIsDownloading: Bool = {
                if case .downloading = ParakeetEngine.shared.state { return true }
                return !ParakeetEngine.shared.isReady && !ParakeetEngine.hasCompleteModel()
            }()
            if parakeetIsDownloading {
                log.info("Dictation fast-engine miss: Parakeet is still downloading — Whisper fallback")
            } else {
                // Silence trim (latency audit 31.10, item 2): Silero cuts
                // the lead, the tail and long pauses, so the phrase fits
                // fewer of Parakeet's 15 s windows. No VAD → untrimmed.
                let trim = await DictationSilenceTrim.run(samples)
                let audioSec = String(format: "%.1f", Double(samples.count) / 16_000)
                if trim.skipsParakeet, !isDaisyHold {
                    // A long hold Silero heard no speech in and that never
                    // got loud: room tone. An empty dictation — no
                    // Parakeet, and no Whisper either: its pass starts
                    // from the same VAD at a stricter threshold. A short
                    // or loud «silent» hold still goes to Parakeet whole
                    // (`noSpeechSkipsParakeet`), and so does every
                    // Daisy-key hold: there an empty text means «silent
                    // hold» and rewrites the selection.
                    vadHeardNoSpeech = true
                    let loudest = String(format: "%.0f", trim.peakLevelDB ?? -160)
                    log.notice("Parakeet skipped — no speech (VAD \(trim.vadMs, privacy: .public) ms, audio \(audioSec, privacy: .public) s, loudest \(loudest, privacy: .public) dBFS)")
                } else {
                    let trimmedSec = String(format: "%.1f", Double(trim.samples.count) / 16_000)
                    let t_parakeet = Date()
                    do {
                        fastText = try await ParakeetEngine.shared.transcribe(samples: trim.samples)
                        if fastText?.isEmpty != false {
                            log.info("Dictation fast-engine miss: Parakeet returned empty — Whisper fallback")
                        }
                    } catch {
                        fastEngineFailed = longEnoughToBeSpeech
                        log.warning("Dictation fast-engine miss: Parakeet error \(error.localizedDescription, privacy: .public) — Whisper fallback")
                    }
                    log.notice("Parakeet \(ms(t_parakeet), privacy: .public) ms (audio \(audioSec, privacy: .public) s → \(trimmedSec, privacy: .public) s after trim: \(trim.outcome.rawValue, privacy: .public), VAD \(trim.vadMs, privacy: .public) ms)")
                }
            }
        case .appleSpeech:
            // SpeechTranscriber needs a concrete language and macOS 26.
            let localeID = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
            if #available(macOS 26, *), localeID != "auto", !localeID.isEmpty {
                let locale = Locale(identifier: localeID)
                // The two misses below used to share one line ("unsupported
                // or model not installed"), which cost a day of guessing in
                // the field: "unsupported" is permanent and the user must be
                // told, while "not installed yet" fixes itself on the next
                // dictation once the background pull lands. Same fallback,
                // different diagnosis — so they're logged apart.
                if await AppleSpeechEngine.isUsable(locale: locale) {
                    if await AppleSpeechEngine.ensureModelReady(locale: locale) {
                        do {
                            fastText = try await AppleSpeechEngine.shared.transcribe(samples: samples, locale: locale)
                            if fastText?.isEmpty != false {
                                log.info("Dictation fast-engine miss: Apple SpeechAnalyzer returned empty — Whisper fallback")
                            }
                        } catch {
                            fastEngineFailed = longEnoughToBeSpeech
                            log.warning("Dictation fast-engine miss: Apple SpeechAnalyzer error \(error.localizedDescription, privacy: .public) — Whisper fallback")
                        }
                    } else {
                        log.info("Dictation fast-engine miss: Apple model for \(localeID, privacy: .public) not installed (download asked for, or held a day after a failure) — Whisper fallback")
                    }
                } else {
                    log.info("Dictation fast-engine miss: Apple SpeechAnalyzer has no model for \(localeID, privacy: .public) on this OS — Whisper fallback (permanent for this language). Note: the system's own dictation supports more languages than SpeechTranscriber does, so \"my Mac dictates this fine\" and this line can both be true.")
                }
            } else {
                log.info("Dictation fast-engine miss: Apple SpeechAnalyzer needs macOS 26+ and a concrete language (got \(localeID, privacy: .public)) — Whisper fallback")
            }
        }

        let engineUsed: String
        // Speech was captured but nothing could transcribe it (the fast
        // engine threw, Whisper isn't loaded). Not the same as silence: a
        // Daisy-key hold must not read it as a silent hold — that would
        // send the selection off to be rewritten.
        var couldNotTranscribe = false
        if let fastText, !fastText.isEmpty {
            transcriptText = fastText
            engineUsed = settings.dictationEngine == .appleSpeech ? "apple_speech" : settings.dictationEngine.rawValue
        } else {
            engineUsed = "whisper"
            // Whisper path — default, and the automatic fallback when the
            // fast engine is off, errored, or produced nothing (e.g. a
            // sub-0.3 s clip, or Apple's model still downloading).
            //
            // `.dictationFinal` (lite search width + one temperature-
            // fallback retry) instead of `.full`: this decode blocks the
            // paste, and full-width search on a few seconds of speech is
            // latency without measurable quality gain.
            //
            // A fast-engine dictation no longer waits for Whisper at its
            // start (field report 27.10), so the fallback may find it not
            // loaded. It is NOT loaded here: this is the key's release, a
            // load can take a minute (or fail, as in that report), and
            // `.stopping` takes no key. Most misses are silence — a tap, a
            // silent Daisy-key hold over a selection — with nothing to
            // lose; a fast engine that threw says so on the pill.
            if vadHeardNoSpeech {
                transcriptText = ""
            } else if WhisperEngine.shared.isReady {
                let dictFinalState = signposter.beginInterval("dictation_final_pass", id: signposter.makeSignpostID())
                let t_dictFinal = Date()
                let biasTerms = DictationDictionary.shared.biasTerms()
                // The pass reports a failure only through `lastError`
                // (CoreML/ANE error, or `notReady` from a model reload
                // between `isReady` and the slot) and leaves an empty
                // transcript behind — which must not read as silence.
                micTranscriber.clearLastError()
                await micTranscriber.runFinalPass(profile: .dictationFinal, biasTerms: biasTerms)
                signposter.endInterval("dictation_final_pass", dictFinalState)
                log.info("post-stop dictation_final_pass: \(ms(t_dictFinal), privacy: .public)ms")
                var verdict = DictationFallbackVerdict.afterPass(
                    failed: micTranscriber.lastError != nil,
                    sampleCount: samples.count,
                    isDaisyHold: isDaisyHold
                )
                // After a failed pass this is what a streaming caption
                // engine (Apple, the Nemotron preview) put on screen.
                var text = fullTranscriptText
                // The session was cancelled during the retry: no words and
                // no pill — it's not a failure the person needs told about.
                var retryCancelled = false
                if verdict == .retry {
                    log.warning("Dictation Whisper pass failed (\(self.micTranscriber.lastError ?? "", privacy: .public)) — one retry on the captured audio")
                    do {
                        let segments = try await WhisperEngine.shared.transcribe(
                            samples: samples,
                            language: micTranscriber.languageHint,
                            profile: .dictationFinal,
                            biasTerms: biasTerms
                        )
                        text = segments.map(\.text).joined(separator: " ")
                        verdict = DictationFallbackVerdict.afterRetry(failed: false, hasCaptionText: false)
                    } catch is CancellationError {
                        retryCancelled = true
                        verdict = .couldNotTranscribe
                    } catch {
                        let hasCaptionText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        log.error("Dictation Whisper retry failed too: \(error.localizedDescription, privacy: .public)\(hasCaptionText ? " — pasting the live caption's text" : "", privacy: .public)")
                        verdict = DictationFallbackVerdict.afterRetry(failed: true, hasCaptionText: hasCaptionText)
                    }
                }
                if verdict == .couldNotTranscribe {
                    couldNotTranscribe = true
                    if !retryCancelled { presentCouldNotTranscribePill() }
                    transcriptText = ""
                } else {
                    transcriptText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                log.info("Dictation fallback skipped: Whisper isn't loaded (fast engine \(fastEngineFailed ? "failed" : "heard nothing", privacy: .public))")
                if fastEngineFailed {
                    couldNotTranscribe = true
                    presentSpeechModelNotReadyPill()
                }
                transcriptText = ""
            }
        }

        // Local usage stats (powers the Home words/min · total words ·
        // activity widgets). Dictation is otherwise ephemeral, so this is
        // the only record of it — count words + the held duration. A
        // Daisy-key hold is a command, not dictated text: not counted.
        if purpose == .paste {
            UsageStats.shared.record(
                words: UsageStats.wordCount(transcriptText),
                seconds: Double(max(0, durSec)),
                kind: .dictation
            )
            if !transcriptText.isEmpty { ImprovementStats.record(.dictation(engine: engineUsed)) }
        }
        // A screenshot taken moments ago is waiting for context: this
        // dictation belongs in that note, not in whatever window happens
        // to be in front (see `ScreenshotNoteCapture`). The claim is made
        // at key-DOWN, so a long answer isn't cut off by the window
        // expiring while the person is still talking. A failed write
        // falls through to the clipboard — nobody's words vanish because
        // a file couldn't be saved.
        if let pending = pendingScreenshotNote {
            pendingScreenshotNote = nil
            // Same corrections and bookkeeping a pasted dictation gets —
            // vocabulary, brand names, history, voice-profile corpus.
            // Routing around `handle` must not mean routing around those:
            // a note is not a second-class destination, and this dictation
            // still counts toward the profile unlock.
            let prepared = isDaisyHold
                ? DaisyKeyController.corrected(transcriptText)
                : DictationPaste.shared.prepare(transcriptText)
            if ScreenshotNoteCapture.shared.attach(context: prepared, to: pending) {
                ScreenshotNoteCapture.shared.announceAttached(pending)
                if isDaisyHold { ImprovementStats.record(.daisyKeyScreenshotContext) }
                if let dir = sessionDirectory {
                    try? FileManager.default.removeItem(at: dir)
                }
                releaseSessionsFolderTicket()
                reset()
                return
            }
            // Reached when the note write failed OR the transcript was
            // empty after trimming — say which, or this line sends
            // someone hunting a filesystem bug that isn't there.
            let wasEmpty = transcriptText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            log.info("Screenshot note not written (empty=\(wasEmpty, privacy: .public)) — \(wasEmpty ? "reopening the note window" : "falling through to the paste path", privacy: .public)")
            if wasEmpty {
                // Nothing recognized: don't burn the claim — give the
                // window back whole so the person can immediately hold
                // the key and try again (its pill was frozen at claim
                // and restorePending replaces it with a fresh one).
                ScreenshotNoteCapture.shared.restorePending(pending)
                if let dir = sessionDirectory {
                    try? FileManager.default.removeItem(at: dir)
                }
                releaseSessionsFolderTicket()
                reset()
                return
            }
            // Real text, broken write: the words go to the clipboard
            // below; the frozen "hold" pill is moot and timer-less.
            ScreenshotNoteCapture.shared.withdrawHoldHint()
        }
        // The note this hold was answering was thrown away from its pill
        // while we were still decoding. The claim is already nil by now,
        // which on its own reads as "ordinary dictation" — and pasting the
        // cancelled sentence into whatever app is in front is the one
        // outcome the trash exists to prevent. The take goes with the note.
        if screenshotNoteDiscarded {
            log.info("Screenshot note discarded mid-hold — dictation dropped, nothing pasted")
            if let dir = sessionDirectory {
                try? FileManager.default.removeItem(at: dir)
            }
            releaseSessionsFolderTicket()
            reset()
            return
        }
        if case .daisyKeyHold(let token) = purpose {
            // Torn down first — the words and samples are in hand — so the
            // key is free for the next press while the note is written.
            if let dir = sessionDirectory { try? FileManager.default.removeItem(at: dir) }
            releaseSessionsFolderTicket()
            reset()
            if couldNotTranscribe {
                // Words were said and lost to the engine — the pill says
                // why. Neither a note nor a rewrite of the selection.
                log.info("Daisy key hold: nothing could transcribe it — dropped, no note, no rewrite")
                DaisyKeyController.shared.holdAbandoned(token: token)
                return
            }
            await DaisyKeyController.shared.holdFinished(token: token, transcript: transcriptText, samples: samples, durationSec: durSec)
            return
        }
        // Words lost to the engine: the pill already says so — not also
        // «nothing was transcribed», which reads as silence.
        if !couldNotTranscribe {
            DictationPaste.shared.handle(transcript: transcriptText)
            // The drop lands with the words — not over a recording, whose
            // mic would hear it, and not for an empty dictation.
            if settings.recordingSoundsEnabled, !dictatesOverLiveRecording,
               !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SoundEffects.playDictationDone()
            }
        }
        if let dir = sessionDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        releaseSessionsFolderTicket()
        reset()
    }
}

extension RecordingSession {
    /// The dictation's Whisper pass failed and nothing more will be tried:
    /// said on the pill, so it isn't mistaken for silence.
    func presentCouldNotTranscribePill() {
        let text = String(localized: "Daisy couldn’t transcribe what you said. Try again.")
        WidgetBubbleCenter.shared.present(WidgetBubbleContent(text: text), notificationTitle: "Daisy")
    }
}

/// What a dictation's Whisper fallback pass came to. A failed pass leaves
/// an empty transcript that must never be read as silence — for a
/// Daisy-key hold silence means «rewrite the selection».
nonisolated enum DictationFallbackVerdict: Equatable {
    /// Use the text (empty = the person said nothing, or a tap).
    case text
    /// The pass failed on a clip long enough to be speech: decode the
    /// captured samples once more.
    case retry
    /// Failed with nothing left to try: the pill, the words are lost.
    case couldNotTranscribe

    /// FluidAudio's and the dictation's floor for speech (0.3 s).
    static let speechFloorSamples = 4_800

    /// A failed pass on a clip shorter than speech is a tap — not a failure
    /// to report (`longEnoughToBeSpeech`) — except for a Daisy-key hold,
    /// where an empty text would rewrite the selection.
    static func afterPass(failed: Bool, sampleCount: Int, isDaisyHold: Bool) -> Self {
        guard failed else { return .text }
        if sampleCount >= speechFloorSamples { return .retry }
        return isDaisyHold ? .couldNotTranscribe : .text
    }

    /// A failed retry still has the words when a streaming caption engine
    /// showed them during the hold (the failed pass leaves its lines).
    static func afterRetry(failed: Bool, hasCaptionText: Bool) -> Self {
        failed && !hasCaptionText ? .couldNotTranscribe : .text
    }
}
