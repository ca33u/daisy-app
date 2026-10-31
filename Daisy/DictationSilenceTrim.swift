//
//  DictationSilenceTrim.swift
//  Daisy
//
//  Silence trim before Parakeet (dictation latency audit vs Handy,
//  31.10, item 2). FluidAudio runs Parakeet in 15 s windows: a phrase of
//  16–28 s pays for a second window, 28–41 s for a third, and much of
//  what fills them is the silence before the first word, after the last
//  one and in the pauses. Silero VAD (the model Whisper's pre-pass
//  already loads) finds the speech; this cuts the lead and the tail down
//  to a margin and squeezes long pauses, so ~20 s of speech fits one
//  window. Handy does the same while recording.
//
//  Never a reason for a dictation to fail or wait: no VAD (not loaded,
//  or it threw) sends the buffer as it was. VAD that heard no speech at
//  all skips Parakeet only for a long, quiet hold (room tone); a short
//  or loud one still goes to Parakeet whole — whispers, a word said at
//  the press and Bluetooth headset audio can score low in every frame.
//

import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

nonisolated enum DictationSilenceTrim {
    static let sampleRate = 16_000
    /// Kept before the first speech and after the last. Silero only
    /// knows where speech starts to its 256 ms frame, and a soft first
    /// syllable can sit at the edge of the frame it's heard in — so the
    /// lead is wider than Handy's.
    static let leadMarginSec = 0.50
    static let tailMarginSec = 0.45
    /// A pause longer than this is squeezed: 0.15 s kept after the speech
    /// before it, 0.30 s before the speech that resumes (the same frame
    /// argument as the lead). Shorter pauses stay — they are phrasing.
    static let longPauseSec = 0.80
    static let pauseKeptAfterSec = 0.15
    static let pauseKeptBeforeSec = 0.30
    /// FluidAudio's floor for Parakeet (`ASRConstants.minimumAudioDurationSeconds`).
    /// A trim that would leave less than this sends the untrimmed buffer.
    static let minimumKeptSec = 0.30

    enum Outcome: String, Equatable, Sendable {
        /// VAD isn't loaded or failed: the untrimmed buffer goes on.
        case noVAD
        /// VAD ran and heard nothing — `noSpeechSkipsParakeet` decides
        /// whether that's enough to call it an empty dictation.
        case noSpeech
        /// Speech was heard but the trim would leave too little for
        /// Parakeet: the untrimmed buffer goes on.
        case tooShort
        /// Nothing worth cutting.
        case unchanged
        case trimmed
    }

    struct Plan: Equatable, Sendable {
        let outcome: Outcome
        /// Sample ranges to keep, in order — only for `.trimmed`.
        let keep: [Range<Int>]
    }

    /// What to keep of a buffer of `sampleCount` samples, given the speech
    /// ranges Silero found (`nil`: no VAD). Pure — the unit tests' entry.
    static func plan(sampleCount: Int, speech: [Range<Int>]?) -> Plan {
        guard let speech else { return Plan(outcome: .noVAD, keep: []) }
        let spans = speech
            .map { range -> Range<Int> in
                let lower = min(max(0, range.lowerBound), max(0, sampleCount))
                return lower..<max(lower, min(sampleCount, range.upperBound))
            }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard let first = spans.first else { return Plan(outcome: .noSpeech, keep: []) }

        let rate = Double(sampleRate)
        let lead = Int(leadMarginSec * rate)
        let tail = Int(tailMarginSec * rate)
        let longPause = Int(longPauseSec * rate)
        let keptAfter = Int(pauseKeptAfterSec * rate)
        let keptBefore = Int(pauseKeptBeforeSec * rate)

        var keep: [Range<Int>] = []
        var start = max(0, first.lowerBound - lead)
        var end = first.upperBound
        for span in spans.dropFirst() {
            if span.lowerBound - end > longPause {
                keep.append(start..<min(sampleCount, end + keptAfter))
                start = max(0, span.lowerBound - keptBefore)
            }
            end = max(end, span.upperBound)
        }
        keep.append(start..<min(sampleCount, end + tail))

        let kept = keep.reduce(0) { $0 + $1.count }
        if kept < Int(minimumKeptSec * rate) { return Plan(outcome: .tooShort, keep: []) }
        if keep == [0..<sampleCount] { return Plan(outcome: .unchanged, keep: []) }
        return Plan(outcome: .trimmed, keep: keep)
    }

    /// The samples Parakeet gets under `plan`: the kept ranges joined for
    /// `.trimmed`, the buffer untouched otherwise (a `.noSpeech` buffer
    /// that still goes to Parakeet goes whole).
    static func apply(_ plan: Plan, to samples: [Float]) -> [Float] {
        switch plan.outcome {
        case .trimmed:
            var out: [Float] = []
            out.reserveCapacity(plan.keep.reduce(0) { $0 + $1.count })
            for range in plan.keep { out.append(contentsOf: samples[range.clamped(to: samples.indices)]) }
            return out
        case .noSpeech, .noVAD, .tooShort, .unchanged:
            return samples
        }
    }

    /// Under this, a hold Silero called silent still goes to Parakeet: a
    /// word said right at the press is a short hold.
    static let noSpeechShortHoldSec = 1.5
    /// A hold whose `peakLevelDB` is above this still goes to Parakeet
    /// when Silero called it silent; room tone sits far below (-60 dBFS
    /// and lower), a whisper at the mic above.
    static let noSpeechLoudDB = -45.0

    /// Silero heard no speech: skip Parakeet (an empty dictation) only for
    /// a long hold that never got loud. Pure — the tests' decision table.
    static func noSpeechSkipsParakeet(sampleCount: Int, peakLevelDB: Double) -> Bool {
        Double(sampleCount) / Double(sampleRate) >= noSpeechShortHoldSec && peakLevelDB <= noSpeechLoudDB
    }

    /// How loud a 16 kHz buffer gets, in dBFS: the RMS of its third-
    /// loudest 100 ms window (50 ms hop). Not the loudest — one keyboard
    /// click or mic bump fills a window or two; a spoken word, 200 ms and
    /// more, fills several.
    static func peakLevelDB(_ samples: [Float], windowSec: Double = 0.1) -> Double {
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration > 0 else { return -160 }
        var levels: [Double] = []
        var start = 0.0
        repeat {
            levels.append(WhisperEngine.rmsDB(samples, from: start, to: min(duration, start + windowSec)))
            start += windowSec / 2
        } while start + windowSec / 2 < duration
        levels.sort(by: >)
        return levels[min(2, levels.count - 1)]
    }

    struct Result: Sendable {
        /// What Parakeet gets — the whole buffer unless `.trimmed`.
        let samples: [Float]
        let outcome: Outcome
        let vadMs: Int
        /// `.noSpeech` only: the buffer's `peakLevelDB`, for `noSpeechSkipsParakeet`.
        let peakLevelDB: Double?

        var skipsParakeet: Bool {
            guard outcome == .noSpeech, let peakLevelDB else { return false }
            return DictationSilenceTrim.noSpeechSkipsParakeet(sampleCount: samples.count, peakLevelDB: peakLevelDB)
        }
    }

    /// Run Silero over a dictation buffer and trim it. VAD inference runs
    /// on FluidAudio's `VadManager` actor and the cut off the main actor;
    /// neither waits for a model load.
    @MainActor
    static func run(_ samples: [Float]) async -> Result {
        let start = Date()
        let speech = await WhisperEngine.shared.dictationSpeechRanges(samples: samples)
        let vadMs = Int(Date().timeIntervalSince(start) * 1000)
        return await cut(samples, speech: speech, vadMs: vadMs)
    }

    @concurrent
    private static func cut(_ samples: [Float], speech: [Range<Int>]?, vadMs: Int) async -> Result {
        let plan = plan(sampleCount: samples.count, speech: speech)
        return Result(
            samples: apply(plan, to: samples),
            outcome: plan.outcome,
            vadMs: vadMs,
            peakLevelDB: plan.outcome == .noSpeech ? peakLevelDB(samples) : nil
        )
    }

    #if canImport(FluidAudio)
    /// Silero settings for the trim. More permissive than Whisper's
    /// pre-pass (entry 0.35 vs 0.85): a missed quiet word costs the
    /// person their words, a kept noise only costs a few milliseconds. No
    /// padding (`plan` adds the margins) and no length cap (nothing here
    /// is decoded span by span).
    static var vadConfig: VadSegmentationConfig {
        var cfg = VadSegmentationConfig.default
        cfg.minSpeechDuration = 0.10
        cfg.minSilenceDuration = 0.30
        cfg.speechPadding = 0
        cfg.maxSpeechDuration = .infinity
        // Entry threshold = negative + offset (FluidAudio derives it so).
        cfg.negativeThreshold = 0.20
        cfg.negativeThresholdOffset = 0.15
        return cfg
    }
    #endif
}
