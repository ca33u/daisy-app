//
//  PhoneSpeakerAssignment.swift
//  Daisy
//
//  session-format.md §3.6 (backlog 7 B-1): a session recorded on the
//  phone has everyone in `microphone.caf`, so §2.1's "the microphone is
//  the owner" does not hold. After the microphone track is diarized
//  whole, this decides which cluster is the owner — by the stored
//  owner voice profile — and turns the rest into `Remote A`, `Remote B`,
//  … exactly as system-stream clusters on the Mac.
//
//  The one rule that must not bend: when nothing matches the owner, no
//  cluster gets the display name. `Remote A` on the owner's own words is
//  fixed with one rename; the owner's name on someone else's words is
//  a wrong record that reads as true.
//
//  Also here: `OwnerVoice` — the owner's embedding, learnt from Mac
//  recordings where the microphone IS the owner (§2.1), and blended
//  over sessions so one bad mic day doesn't own the profile.
//

import Foundation
import os

nonisolated enum PhoneSpeakerAssignment {
    struct Result: Sendable, Equatable {
        var segments: [TranscriptSegment]
        /// Centroids of the `Remote` clusters, under their new labels —
        /// what goes to `speakers.json` so they can be named and enrolled.
        var centroids: [String: [Float]]
        /// The diarization label recognised as the owner, if any.
        var ownerCluster: String?
        /// Best owner similarity seen, for the log.
        var ownerScore: Float
    }

    /// `segments` come from `mergeBySpeaker` over the mic track
    /// (`speakerId` = diarization label or nil), `centroids` from the
    /// same pass. `owner` is the stored owner embedding, nil when none.
    static func apply(
        segments: [TranscriptSegment],
        centroids: [String: [Float]],
        owner: [Float]?,
        threshold: Float = SpeakerProfileStore.matchThreshold
    ) -> Result {
        // Clusters in order of first appearance — the same order the
        // Mac labels system-stream clusters.
        var order: [String] = []
        for segment in segments.sorted(by: { $0.startSec < $1.startSec }) {
            if let id = segment.speakerId, !order.contains(id) { order.append(id) }
        }
        for id in centroids.keys.sorted() where !order.contains(id) { order.append(id) }

        var ownerCluster: String?
        var ownerScore: Float = 0
        if let owner, !owner.isEmpty {
            for id in order {
                guard let centroid = centroids[id], centroid.count == owner.count else { continue }
                let score = speakerCosineSimilarity(owner, centroid)
                if score > ownerScore { ownerScore = score; ownerCluster = id }
            }
            if ownerScore < threshold { ownerCluster = nil }
        }

        // Remaining clusters → A, B, C… in order of first appearance.
        var relabel: [String: String] = [:]
        var next = 0
        for id in order where id != ownerCluster {
            relabel[id] = String(UnicodeScalar(UInt8(65 + next % 26)))
            next += 1
        }

        let out: [TranscriptSegment] = segments.map { segment in
            var copy = segment
            if let id = segment.speakerId, id == ownerCluster {
                copy.source = .microphone      // the display name / "Me"
                copy.speakerId = nil
            } else {
                copy.source = .systemAudio     // "Remote A" … or bare "Remote"
                copy.speakerId = segment.speakerId.flatMap { relabel[$0] }
            }
            return copy
        }
        var remoteCentroids: [String: [Float]] = [:]
        for (id, centroid) in centroids {
            if let label = relabel[id] { remoteCentroids[label] = centroid }
        }
        return Result(segments: out, centroids: remoteCentroids, ownerCluster: ownerCluster, ownerScore: ownerScore)
    }
}

/// The owner's voice, learnt from the microphone track of Mac
/// recordings — the one stream that is the owner by definition.
nonisolated enum OwnerVoice {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "OwnerVoice")
    /// How much of the mic track to listen to. Three minutes of one
    /// person is plenty for a 256-d centroid; a two-hour meeting is not
    /// re-read for it.
    static let maxSeconds: Double = 180

    /// The dominant cluster's centroid over the first `maxSeconds` of
    /// the given microphone archives, or nil when nothing was heard.
    static func embedding(fromMicrophoneArchives urls: [URL]) async -> [Float]? {
        guard !urls.isEmpty else { return nil }
        let reader = ArchiveBlockReader(urls: urls, blockSeconds: 30, cutSearchSeconds: 0)
        guard let pass = await DiarizationEngine.shared.makeBlockPass() else { return nil }
        var heard: Double = 0
        while heard < maxSeconds, let block = reader.nextBlock() {
            pass.process(samples: block.samples, atSec: block.startSec)
            heard += Double(block.samples.count) / Double(ArchiveBlockReader.sampleRate)
        }
        let output = await MainActor.run { pass.finish() }
        guard !output.centroids.isEmpty else { return nil }
        // Longest-speaking cluster wins: on a Mac mic track that is the
        // owner; a guest heard through the speakers is shorter and quieter.
        var seconds: [String: Double] = [:]
        for span in output.spans { seconds[span.speakerId, default: 0] += span.endSec - span.startSec }
        guard let best = seconds.max(by: { $0.value < $1.value })?.key,
              let centroid = output.centroids[best] else { return output.centroids.values.first }
        log.info("Owner voice from \(Int(heard), privacy: .public) s of mic audio, cluster \(best, privacy: .public) spoke \(Int(seconds[best] ?? 0), privacy: .public) s")
        return centroid
    }
}
