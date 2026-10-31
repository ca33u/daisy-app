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

    @Test("Lead and tail are cut down to 0.3 s before and 0.45 s after the speech")
    func leadAndTailMargins() {
        let plan = Trim.plan(sampleCount: Self.s(10), speech: [Self.span(3, 5)])
        #expect(plan.outcome == .trimmed)
        #expect(plan.keep == [Self.s(2.7)..<Self.s(5.45)])
    }

    @Test("Margins stop at the buffer's edges")
    func marginsClampToBuffer() {
        let plan = Trim.plan(sampleCount: Self.s(6), speech: [Self.span(0.1, 5.8)])
        #expect(plan.outcome == .unchanged)
        #expect(Trim.plan(sampleCount: Self.s(6), speech: [Self.span(0.1, 4)]).keep == [0..<Self.s(4.45)])
    }

    @Test("A pause over 0.8 s is squeezed to 0.3 s; a shorter one is left alone")
    func pauseCompression() {
        let plan = Trim.plan(sampleCount: Self.s(20), speech: [
            Self.span(1, 3),
            Self.span(3.5, 5),     // 0.5 s pause: phrasing, kept whole
            Self.span(9, 10),      // 4 s pause: squeezed
        ])
        #expect(plan.outcome == .trimmed)
        #expect(plan.keep == [Self.s(0.7)..<Self.s(5.15), Self.s(8.85)..<Self.s(10.45)])
        let kept = plan.keep.reduce(0) { $0 + $1.count }
        // 2 + 0.5 + 1.5 + 1 s of speech and phrasing, 0.3 + 0.45 margins, 0.3 s of the long pause.
        #expect(abs(kept - Self.s(6.05)) <= 2)
        let samples = (0..<Self.s(20)).map { Float($0) }
        let out = Trim.apply(plan, to: samples)
        #expect(out.count == kept)
        #expect(out.first == Float(Self.s(0.7)))
        #expect(out.last == Float(Self.s(10.45) - 1))
    }

    @Test("Overlapping and unsorted spans are merged")
    func unsortedSpans() {
        let plan = Trim.plan(sampleCount: Self.s(10), speech: [Self.span(4, 6), Self.span(2, 4.5)])
        #expect(plan.keep == [Self.s(1.7)..<Self.s(6.45)])
    }

    @Test("No speech at all is an empty dictation")
    func noSpeech() {
        let plan = Trim.plan(sampleCount: Self.s(5), speech: [])
        #expect(plan.outcome == .noSpeech)
        #expect(Trim.apply(plan, to: [Float](repeating: 0.1, count: Self.s(5))).isEmpty)
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
