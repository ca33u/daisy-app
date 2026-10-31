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
//  all is an empty dictation — Parakeet isn't called.
//

import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

nonisolated enum DictationSilenceTrim {
    static let sampleRate = 16_000
    /// Kept before the first speech and after the last — Handy's margins.
    /// Silero decides in 256 ms frames; a soft first syllable can sit at
    /// the edge of the frame it's heard in.
    static let leadMarginSec = 0.30
    static let tailMarginSec = 0.45
    /// A pause longer than this is squeezed to `keptPauseSec`, half on
    /// each side; shorter ones stay as they were — they are phrasing.
    static let longPauseSec = 0.80
    static let keptPauseSec = 0.30
    /// FluidAudio's floor for Parakeet (`ASRConstants.minimumAudioDurationSeconds`).
    /// A trim that would leave less than this sends the untrimmed buffer.
    static let minimumKeptSec = 0.30

    enum Outcome: String, Equatable, Sendable {
        /// VAD isn't loaded or failed: the untrimmed buffer goes on.
        case noVAD
        /// VAD ran and heard nothing: an empty dictation.
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
        let keptPause = Int(keptPauseSec * rate)
        let keptBefore = keptPause / 2
        let keptAfter = keptPause - keptBefore

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
    /// `.trimmed`, nothing for `.noSpeech`, the buffer untouched otherwise.
    static func apply(_ plan: Plan, to samples: [Float]) -> [Float] {
        switch plan.outcome {
        case .trimmed:
            var out: [Float] = []
            out.reserveCapacity(plan.keep.reduce(0) { $0 + $1.count })
            for range in plan.keep { out.append(contentsOf: samples[range.clamped(to: samples.indices)]) }
            return out
        case .noSpeech:
            return []
        case .noVAD, .tooShort, .unchanged:
            return samples
        }
    }

    struct Result: Sendable {
        let samples: [Float]
        let outcome: Outcome
        let vadMs: Int
    }

    /// Run Silero over a dictation buffer and trim it. VAD inference runs
    /// on FluidAudio's `VadManager` actor and the cut off the main actor;
    /// neither waits for a model load.
    @MainActor
    static func run(_ samples: [Float]) async -> Result {
        let start = Date()
        let speech = await WhisperEngine.shared.dictationSpeechRanges(samples: samples)
        let vadMs = Int(Date().timeIntervalSince(start) * 1000)
        let (trimmed, outcome) = await cut(samples, speech: speech)
        return Result(samples: trimmed, outcome: outcome, vadMs: vadMs)
    }

    @concurrent
    private static func cut(_ samples: [Float], speech: [Range<Int>]?) async -> ([Float], Outcome) {
        let plan = plan(sampleCount: samples.count, speech: speech)
        return (apply(plan, to: samples), plan.outcome)
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
