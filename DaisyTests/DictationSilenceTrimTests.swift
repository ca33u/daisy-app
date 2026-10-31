import Foundation
import Testing
@testable import Daisy

/// Dictation latency audit vs Handy (31.10), item 2: Silero trims the
/// silence before Parakeet so a phrase fits fewer 15 s windows.
@Suite("Dictation silence trim")
struct DictationSilenceTrimTests {
    typealias Trim = DictationSilenceTrim

    private static func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }
    private static func span(_ from: Double, _ to: Double) -> Range<Int> { s(from)..<s(to) }

    @Test("Lead and tail are cut down to 0.5 s before and 0.45 s after the speech")
    func leadAndTailMargins() {
        let plan = Trim.plan(sampleCount: Self.s(10), speech: [Self.span(3, 5)])
        #expect(plan.outcome == .trimmed)
        #expect(plan.keep == [Self.s(2.5)..<Self.s(5.45)])
    }

    @Test("Margins stop at the buffer's edges")
    func marginsClampToBuffer() {
        let plan = Trim.plan(sampleCount: Self.s(6), speech: [Self.span(0.1, 5.8)])
        #expect(plan.outcome == .unchanged)
        #expect(Trim.plan(sampleCount: Self.s(6), speech: [Self.span(0.1, 4)]).keep == [0..<Self.s(4.45)])
    }

    @Test("A pause over 0.8 s is squeezed to 0.45 s; a shorter one is left alone")
    func pauseCompression() {
        let plan = Trim.plan(sampleCount: Self.s(20), speech: [
            Self.span(1, 3),
            Self.span(3.5, 5),     // 0.5 s pause: phrasing, kept whole
            Self.span(9, 10),      // 4 s pause: squeezed
        ])
        #expect(plan.outcome == .trimmed)
        #expect(plan.keep == [Self.s(0.5)..<Self.s(5.15), Self.s(8.7)..<Self.s(10.45)])
        let kept = plan.keep.reduce(0) { $0 + $1.count }
        // 2 + 0.5 + 1.5 + 1 s of speech and phrasing, 0.5 + 0.45 margins, 0.45 s of the long pause.
        #expect(kept == Self.s(6.4))
        let samples = (0..<Self.s(20)).map { Float($0) }
        let out = Trim.apply(plan, to: samples)
        #expect(out.count == kept)
        #expect(out.first == Float(Self.s(0.5)))
        #expect(out.last == Float(Self.s(10.45) - 1))
    }

    @Test("Speech that resumes after a squeezed pause keeps 0.3 s before it, the speech before keeps 0.15 s")
    func resumptionMargin() {
        let plan = Trim.plan(sampleCount: Self.s(12), speech: [Self.span(2, 5), Self.span(7, 9)])
        #expect(plan.keep.count == 2)
        #expect(plan.keep[0].upperBound == Self.s(5.15))
        #expect(plan.keep[1].lowerBound == Self.s(6.7))
        #expect(Self.s(7) - plan.keep[1].lowerBound >= Self.s(0.3))
        #expect(Self.s(2) - plan.keep[0].lowerBound >= Self.s(0.45))
    }

    @Test("Overlapping and unsorted spans are merged")
    func unsortedSpans() {
        let plan = Trim.plan(sampleCount: Self.s(10), speech: [Self.span(4, 6), Self.span(2, 4.5)])
        #expect(plan.keep == [Self.s(1.5)..<Self.s(6.45)])
    }

    @Test("No speech: the plan says so and the buffer is left whole for whoever still decodes it")
    func noSpeech() {
        let plan = Trim.plan(sampleCount: Self.s(5), speech: [])
        #expect(plan.outcome == .noSpeech)
        let samples = [Float](repeating: 0.1, count: Self.s(5))
        #expect(Trim.apply(plan, to: samples) == samples)
        // Spans that fall outside the buffer are no speech either.
        #expect(Trim.plan(sampleCount: Self.s(5), speech: [Self.span(6, 7)]).outcome == .noSpeech)
    }

    @Test("A trim that would leave under 0.3 s sends the untrimmed buffer")
    func tooShortKeepsBuffer() {
        // A 50 ms blip in a 0.25 s clip: the margins can't grow past the clip.
        let tiny = Trim.plan(sampleCount: Self.s(0.25), speech: [Self.span(0, 0.05)])
        #expect(tiny.outcome == .tooShort)
        let samples = [Float](repeating: 0.2, count: Self.s(0.25))
        #expect(Trim.apply(tiny, to: samples) == samples)
    }

    @Test("Without VAD the buffer goes on untouched")
    func noVADPassthrough() {
        let plan = Trim.plan(sampleCount: Self.s(5), speech: nil)
        #expect(plan.outcome == .noVAD)
        let samples = (0..<Self.s(5)).map { Float($0 % 7) }
        #expect(Trim.apply(plan, to: samples) == samples)
    }

    @Test("A Parakeet window's worth of speech with long pauses fits one window after the trim")
    func fitsOneWindow() {
        // 20 s hold: 1.5 s of silence, then four 3 s phrases with 1.5 s pauses, then silence.
        let speech = [Self.span(1.5, 4.5), Self.span(6, 9), Self.span(10.5, 13.5), Self.span(15, 18)]
        let plan = Trim.plan(sampleCount: Self.s(20), speech: speech)
        let kept = Double(plan.keep.reduce(0) { $0 + $1.count }) / 16_000
        #expect(kept < 15)
    }

    // MARK: Silero said «no speech» (review M2)

    @Test("Silero's «no speech» skips Parakeet only for a long, quiet hold",
          arguments: [
            // (seconds, loudest dBFS, skips)
            (0.8, -70.0, false),   // a word at the press, too quiet for Silero
            (0.8, -30.0, false),
            (1.4, -70.0, false),
            (3.0, -30.0, false),   // a whisper or HFP audio Silero scored low
            (3.0, -44.0, false),
            (1.5, -45.0, true),
            (3.0, -60.0, true),    // room tone
            (20.0, -75.0, true),
          ])
    func noSpeechDecisionTable(seconds: Double, loudestDB: Double, skips: Bool) {
        #expect(Trim.noSpeechSkipsParakeet(sampleCount: Self.s(seconds), peakLevelDB: loudestDB) == skips)
    }

    @Test("A spoken burst sets the level; zeros and an empty buffer read as silence")
    func peakLevel() {
        #expect(Trim.peakLevelDB([]) == -160)
        #expect(Trim.peakLevelDB([Float](repeating: 0, count: Self.s(3))) <= -150)
        var samples = [Float](repeating: 0.0005, count: Self.s(4))   // ≈ -66 dBFS
        for i in Self.s(2)..<Self.s(2.12) { samples[i] = 0.1 * sin(Float(i) * 0.3) }   // ≈ -23 dBFS for 120 ms
        let level = Trim.peakLevelDB(samples)
        #expect(level > -30 && level < -20)
        #expect(Trim.noSpeechSkipsParakeet(sampleCount: samples.count, peakLevelDB: level) == false)
    }

    @Test("One click in a long room-tone hold doesn't make it loud")
    func clickIsNotSpeech() {
        var samples = [Float](repeating: 0.0005, count: Self.s(20))   // ≈ -66 dBFS
        for i in Self.s(9)..<Self.s(9.01) { samples[i] = 0.8 }        // a 10 ms click
        let level = Trim.peakLevelDB(samples)
        #expect(level < -60)
        #expect(Trim.noSpeechSkipsParakeet(sampleCount: samples.count, peakLevelDB: level))
    }

    @Test("Only a «no speech» result can skip Parakeet")
    func resultSkips() {
        let quiet = [Float](repeating: 0.0005, count: Self.s(3))
        let noSpeech = Trim.Result(samples: quiet, outcome: .noSpeech, vadMs: 1, peakLevelDB: -66)
        #expect(noSpeech.skipsParakeet)
        let noVAD = Trim.Result(samples: quiet, outcome: .noVAD, vadMs: 0, peakLevelDB: nil)
        #expect(!noVAD.skipsParakeet)
        let loud = Trim.Result(samples: quiet, outcome: .noSpeech, vadMs: 1, peakLevelDB: -20)
        #expect(!loud.skipsParakeet)
    }
}

/// Review M1: a failed Whisper fallback pass is retried once and then
/// said on a pill — never read as silence (a Daisy-key hold would rewrite
/// the selection).
@Suite("Dictation fallback verdict")
struct DictationFallbackVerdictTests {
    typealias Verdict = DictationFallbackVerdict

    @Test("A pass that worked is used as it is, empty or not")
    func successIsText() {
        for hold in [false, true] {
            #expect(Verdict.afterPass(failed: false, sampleCount: 0, isDaisyHold: hold) == .text)
            #expect(Verdict.afterPass(failed: false, sampleCount: 160_000, isDaisyHold: hold) == .text)
        }
    }

    @Test("A failed pass on speech-length audio is retried once")
    func failedPassRetries() {
        for hold in [false, true] {
            #expect(Verdict.afterPass(failed: true, sampleCount: 4_800, isDaisyHold: hold) == .retry)
            #expect(Verdict.afterPass(failed: true, sampleCount: 320_000, isDaisyHold: hold) == .retry)
        }
    }

    @Test("A failed pass on a tap is an empty dictation, but never a silent Daisy-key hold")
    func failedTap() {
        #expect(Verdict.afterPass(failed: true, sampleCount: 4_799, isDaisyHold: false) == .text)
        #expect(Verdict.afterPass(failed: true, sampleCount: 4_799, isDaisyHold: true) == .couldNotTranscribe)
    }

    @Test("A failed retry is «couldn't transcribe» unless a live caption already has the words")
    func failedRetry() {
        #expect(Verdict.afterRetry(failed: true, hasCaptionText: false) == .couldNotTranscribe)
        #expect(Verdict.afterRetry(failed: true, hasCaptionText: true) == .text)
        #expect(Verdict.afterRetry(failed: false, hasCaptionText: false) == .text)
    }
}

/// Item 4: a dictation runs no live Whisper unless a streaming engine
/// drives its caption.
@MainActor
@Suite("Dictation live tier")
struct DictationLiveTierTests {
    @Test("Parakeet and Whisper dictations run no live Whisper windows")
    func batchEnginesRunNoLiveWindows() {
        for setting in LiveTranscriptionTier.allCases {
            #expect(RecordingSession.liveTier(mode: .dictation, setting: setting, dictationEngine: .parakeet, nemotronLive: false) == .off)
            #expect(RecordingSession.liveTier(mode: .dictation, setting: setting, dictationEngine: .whisper, nemotronLive: false) == .off)
        }
    }

    @Test("Apple's live caption and the Nemotron preview keep the live path")
    func streamingCaptionsKeepLivePath() {
        #expect(RecordingSession.liveTier(mode: .dictation, setting: .off, dictationEngine: .appleSpeech, nemotronLive: false) == .full)
        #expect(RecordingSession.liveTier(mode: .dictation, setting: .off, dictationEngine: .parakeet, nemotronLive: true) == .full)
        #expect(RecordingSession.liveTier(mode: .dictation, setting: .lite, dictationEngine: .whisper, nemotronLive: true) == .full)
    }

    @Test("Meetings and voice notes keep the person's tier")
    func meetingsKeepSetting() {
        for setting in LiveTranscriptionTier.allCases {
            #expect(RecordingSession.liveTier(mode: .meeting, setting: setting, dictationEngine: .parakeet, nemotronLive: true) == setting)
            #expect(RecordingSession.liveTier(mode: .voiceNote, setting: setting, dictationEngine: .appleSpeech, nemotronLive: false) == setting)
        }
    }
}
