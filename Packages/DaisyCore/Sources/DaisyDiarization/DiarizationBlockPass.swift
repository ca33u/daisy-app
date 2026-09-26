//
//  DiarizationBlockPass.swift
//  DaisyDiarization
//
//  Diarization of a whole recording, block by block, so memory follows
//  the block and not the recording (25.09). Backlog 18 fed an 80-minute
//  file in one piece: 1296 MB for diarization alone, 1750 MB with
//  Whisper resident — above anything the app had ever peaked at.
//
//  Ported from daisy-app `DiarizationBlockPass`: ONE `DiarizerManager`
//  for the whole recording. Its speaker database persists across calls,
//  so a block boundary is just one more of its own chunk boundaries —
//  the same voice keeps its id from the first block to the last. `atTime`
//  makes every span session-absolute.
//
//  `process` is synchronous and CoreML-heavy: call it off the main
//  actor, one block at a time.
//

import DaisyCore
import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

public nonisolated final class DiarizationBlockPass: @unchecked Sendable {
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Diarization")
    #if canImport(FluidAudio)
    private let manager: DiarizerManager
    private var raw: [TimedSpeakerSegment] = []

    init(manager: DiarizerManager) { self.manager = manager }
    #endif

    public private(set) var secondsHeard: Double = 0
    /// Blocks handed in and blocks that failed, with the first error —
    /// so «no voices» can be told apart from «could not listen».
    public private(set) var blocks = 0
    public private(set) var failedBlocks = 0
    public private(set) var firstError: String?

    /// One block of 16 kHz mono samples starting at `atSec`. Blocks under
    /// three seconds are skipped (as on the Mac); a failing block loses
    /// its own spans only.
    public func process(samples: [Float], atSec: Double) {
        #if canImport(FluidAudio)
        guard samples.count > PhoneDiarizer.minimumSamples else { return }
        blocks += 1
        do {
            let result = try manager.performCompleteDiarization(samples, atTime: atSec)
            raw.append(contentsOf: result.segments)
            secondsHeard += Double(samples.count) / 16_000
        } catch {
            failedBlocks += 1
            if firstError == nil { firstError = String(describing: error) }
            log.error("Diarization of the block at \(Int(atSec), privacy: .public) s failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Everything so far as spans labelled A, B… by first appearance, and
    /// each voice's centroid (mean of its segments' embeddings, L2
    /// normalised — what a profile is compared with).
    public func finish() -> DiarizationOutcome {
        #if canImport(FluidAudio)
        var labels: [String: String] = [:]
        var next = 0
        for segment in raw.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where labels[segment.speakerId] == nil {
            labels[segment.speakerId] = String(UnicodeScalar(UInt8(65 + min(next, 25))))
            next += 1
        }
        let spans = raw.sorted { $0.startTimeSeconds < $1.startTimeSeconds }.compactMap { segment -> SpeakerSpan? in
            guard let label = labels[segment.speakerId] else { return nil }
            return SpeakerSpan(speakerId: label, startSec: Double(segment.startTimeSeconds), endSec: Double(segment.endTimeSeconds))
        }
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for segment in raw {
            guard let label = labels[segment.speakerId], !segment.embedding.isEmpty else { continue }
            if var running = sums[label] {
                for i in running.indices where i < segment.embedding.count { running[i] += segment.embedding[i] }
                sums[label] = running
            } else {
                sums[label] = segment.embedding
            }
            counts[label, default: 0] += 1
        }
        var centroids: [String: [Float]] = [:]
        for (label, sum) in sums {
            var mean = sum.map { $0 / Float(counts[label] ?? 1) }
            let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { mean = mean.map { $0 / norm } }
            centroids[label] = mean
        }
        return DiarizationOutcome(spans: spans, centroids: centroids, seconds: secondsHeard)
        #else
        return DiarizationOutcome(spans: [], centroids: [:], seconds: 0)
        #endif
    }
}
