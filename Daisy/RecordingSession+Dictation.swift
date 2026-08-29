//
//  RecordingSession+Dictation.swift
//  Daisy
//
//  Post-Stop handling for DICTATION mode, lifted out of the giant `stop()`
//  in RecordingSession.swift (architecture cleanup — behaviour unchanged).
//  Dictation is fully ephemeral: transcribe the held mic buffer (fast
//  engine → Whisper fallback), optionally rewrite it in the user's voice,
//  record usage, paste, and tear the session down. Nothing is saved to
//  Library.
//

import Foundation
import os

extension RecordingSession {
    /// Which language this dictation is in, for picking the voice
    /// profile that rewrites it. A pinned locale is the answer whenever
    /// there is one — the person said it themselves; otherwise the
    /// detector reads the text we just produced. nil when neither can
    /// say, which the store reads as "no known mismatch" and so applies
    /// no cross-language guard.
    static func dictationLanguage(of text: String, settings: AppSettings) -> String? {
        let pinned = settings.dictationLocale.isEmpty
            ? settings.defaultTranscriptionLocale
            : settings.dictationLocale
        if let code = VoiceCorpusClassifier.normalized(pinned) { return code }
        return LanguageDetector.detect(text)
    }

    /// Finalize a `.dictation` session and paste the result. `durSec` is
    /// the recorded length (passed from `stop()`, which already computed
    /// it). Runs INLINE on Stop — the paste waits on it — so every step is
    /// latency-conscious (lite decode, an 8 s polish deadline).
    func finishDictation(durSec: Int) async {
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "Dictation")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        var transcriptText: String
        let samples = micTranscriber.capturedSamples

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
        switch settings.dictationEngine {
        case .whisper:
            break
        case .parakeet:
            do {
                fastText = try await ParakeetEngine.shared.transcribe(samples: samples)
                if fastText?.isEmpty != false {
                    log.info("Dictation fast-engine miss: Parakeet returned empty — Whisper fallback")
                }
            } catch {
                log.warning("Dictation fast-engine miss: Parakeet error \(error.localizedDescription, privacy: .public) — Whisper fallback")
            }
        case .appleSpeech:
            // SpeechTranscriber needs a concrete language and macOS 26.
            let localeID = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
            if #available(macOS 26, *), localeID != "auto", !localeID.isEmpty {
                let locale = Locale(identifier: localeID)
                if await AppleSpeechEngine.isUsable(locale: locale),
                   await AppleSpeechEngine.ensureModelReady(locale: locale) {
                    do {
                        fastText = try await AppleSpeechEngine.shared.transcribe(samples: samples, locale: locale)
                        if fastText?.isEmpty != false {
                            log.info("Dictation fast-engine miss: Apple SpeechAnalyzer returned empty — Whisper fallback")
                        }
                    } catch {
                        log.warning("Dictation fast-engine miss: Apple SpeechAnalyzer error \(error.localizedDescription, privacy: .public) — Whisper fallback")
                    }
                } else {
                    log.info("Dictation fast-engine miss: Apple SpeechAnalyzer unusable for locale \(localeID, privacy: .public) (unsupported or model not installed) — Whisper fallback")
                }
            } else {
                log.info("Dictation fast-engine miss: Apple SpeechAnalyzer needs macOS 26+ and a concrete language (got \(localeID, privacy: .public)) — Whisper fallback")
            }
        }

        if let fastText, !fastText.isEmpty {
            transcriptText = fastText
        } else {
            // Whisper path — default, and the automatic fallback when the
            // fast engine is off, errored, or produced nothing (e.g. a
            // sub-0.3 s clip, or Apple's model still downloading).
            //
            // `.dictationFinal` (lite search width + one temperature-
            // fallback retry) instead of `.full`: this decode blocks the
            // paste, and full-width search on a few seconds of speech is
            // latency without measurable quality gain.
            let dictFinalState = signposter.beginInterval("dictation_final_pass", id: signposter.makeSignpostID())
            let t_dictFinal = Date()
            await micTranscriber.runFinalPass(profile: .dictationFinal, biasTerms: DictationDictionary.shared.biasTerms())
            signposter.endInterval("dictation_final_pass", dictFinalState)
            log.info("post-stop dictation_final_pass: \(ms(t_dictFinal), privacy: .public)ms")
            transcriptText = fullTranscriptText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // What the VOICE PROFILE learns from — captured here, before the
        // polish branch below can overwrite `transcriptText` with the
        // model's rewrite. The profile has to learn from the person, not
        // from its own previous output (see `DictationPaste.prepare`).
        let rawText = transcriptText

        // Optional: rewrite in the user's voice via the local profile
        // before pasting. Opt-in (adds one LLM pass); no-op without a
        // generated profile. Failure / timeout → keep the un-polished text.
        //
        // The profile is picked by the language of THIS text: a pinned
        // dictation locale if there is one, otherwise the detector (only
        // run when the polish is actually going to happen — it costs an
        // NL pass). With no profile for that language the store falls
        // back (universal, then largest corpus) and flags it, which puts
        // the cross-language guard into the prompt.
        if settings.polishDictationInMyVoice, !transcriptText.isEmpty,
           let style = VoiceProfileStore.shared.resolveStyle(
               forTextIn: Self.dictationLanguage(of: transcriptText, settings: settings)
           ) {
            let instruction = style.promptInstruction
            if style.isCrossLanguage {
                VoiceProfileStore.shared.noteCrossLanguagePolish(target: style.targetLanguage)
            }
            let polishState = signposter.beginInterval("dictation_polish", id: signposter.makeSignpostID())
            let t_polish = Date()
            if let polished = await Self.polishWithDeadline(
                text: transcriptText, instruction: instruction, seconds: 8
            ), !polished.isEmpty {
                // Count words the rewrite changed (insertions in a word-level
                // diff) for the "fixes made by Daisy" widget.
                let before = transcriptText.split(whereSeparator: { $0.isWhitespace })
                let after = polished.split(whereSeparator: { $0.isWhitespace })
                let changed = after.difference(from: before).insertions.count
                UsageStats.shared.recordFixes(polished: changed)

                // Auto-suggest (Egor 2026-07-25): the polish LLM just
                // restored a Latin brand name we don't cover (not in
                // the built-in table, not in the user's rules) — offer
                // to save it as a permanent Vocabulary correction. Once
                // saved it works on EVERY engine, polish on or off.
                let triggers = Set(
                    DictationDictionary.shared.replacements.map { $0.from.lowercased() }
                )
                if let pair = BrandCorrections.suggestRestoredBrand(
                    original: transcriptText, polished: polished, userTriggers: triggers
                ) {
                    ToastCenter.shared.showAction(
                        String(localized: "Noticed “\(pair.from)” → “\(pair.to)”. Save as a dictation correction?"),
                        actionLabel: String(localized: "Save"),
                        style: .info
                    ) {
                        DictationDictionary.shared.add(
                            DictationReplacement(kind: .correction, from: pair.from, to: pair.to)
                        )
                    }
                }

                transcriptText = polished
            }
            signposter.endInterval("dictation_polish", polishState)
            log.info("post-stop dictation_polish: \(ms(t_polish), privacy: .public)ms")
        }

        // nil when the polish didn't run or changed nothing: `prepare`
        // then feeds the corpus the very text it already corrected,
        // instead of correcting an identical string a second time inside
        // the Stop→paste window.
        func corpusText(_ raw: String) -> String? {
            raw == transcriptText ? nil : raw
        }

        // Local usage stats (powers the Home words/min · total words ·
        // activity widgets). Dictation is otherwise ephemeral, so this is
        // the only record of it — count words + the held duration.
        UsageStats.shared.record(
            words: UsageStats.wordCount(transcriptText),
            seconds: Double(max(0, durSec)),
            kind: .dictation
        )
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
            let prepared = DictationPaste.shared.prepare(transcriptText, corpusText: corpusText(rawText))
            if ScreenshotNoteCapture.shared.attach(context: prepared, to: pending) {
                ScreenshotNoteCapture.shared.announceAttached(pending)
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
        DictationPaste.shared.handle(transcript: transcriptText, corpusText: corpusText(rawText))
        if let dir = sessionDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        releaseSessionsFolderTicket()
        reset()
    }
}
