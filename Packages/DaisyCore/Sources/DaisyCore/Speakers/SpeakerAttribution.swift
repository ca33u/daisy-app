//
//  SpeakerAttribution.swift
//  DaisyCore
//
//  Who said each line, from the voices diarization found — the part of
//  the Mac's pipeline that is plain arithmetic, so the phone and the Mac
//  run the same rules (25.09: diarization on the phone, done properly).
//
//  Ported from daisy-app: `DiarizationEngine.mergeBySpeaker`,
//  `PhoneSpeakerAssignment.apply`, `speakerCosineSimilarity`. Named
//  apart from them on purpose: the Mac's tests import both modules.
//
//  New here: `absorbFleetingVoices`. Backlog 18 found one voice split in
//  two on a short solo recording, and no clustering threshold right for
//  a solo and a two-person file at once.
//

import Foundation

/// A stretch of audio one voice holds, in session seconds.
public nonisolated struct SpeakerSpan: Sendable, Equatable, Codable {
    public var speakerId: String
    public var startSec: Double
    public var endSec: Double

    public init(speakerId: String, startSec: Double, endSec: Double) {
        self.speakerId = speakerId
        self.startSec = startSec
        self.endSec = endSec
    }
}

public nonisolated enum SpeakerAttribution {
    /// §3.6: a cluster is the owner above this cosine to their profile
    /// (the Mac's `SpeakerProfileStore.matchThreshold`).
    public static let ownerMatchThreshold: Float = 0.65

    /// Cosine of two L2-normalised embeddings — a dot product. 0 when
    /// the sizes differ (a profile from another model).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// Each segment takes the voice that covers most of it — at least
    /// `confidenceThreshold` of its length; otherwise it keeps no label
    /// (renders as bare "Remote").
    public static func merge(
        segments: [TranscriptSegment],
        spans: [SpeakerSpan],
        confidenceThreshold: Double = 0.30
    ) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return segments }
        return segments.map { segment in
            var copy = segment
            let length = segment.endSec - segment.startSec
            guard length > 0 else { return copy }
            var best: (id: String, share: Double)?
            for span in spans {
                let overlap = min(segment.endSec, span.endSec) - max(segment.startSec, span.startSec)
                guard overlap > 0 else { continue }
                let share = overlap / length
                if best == nil || share > best!.share { best = (span.speakerId, share) }
            }
            if let best, best.share >= confidenceThreshold { copy.speakerId = best.id }
            return copy
        }
    }

    /// A voice heard only once, for less than this, is not a person of
    /// its own.
    public static let fleetingVoiceSeconds: Double = 4

    /// Backlog 18, measured again 25.09 with the block pass: on a 24 s
    /// note one person spoke, the last 3.4 s came back as a second voice
    /// — one stretch, its centroid unrelated to the first (cosine −0.004,
    /// so closeness cannot catch it). Real second speakers in the test
    /// set spoke 15–105 s. A voice heard in one stretch shorter than
    /// `minSeconds`, next to another voice, goes to the voice nearest in
    /// time; labels are then A, B… by first appearance again.
    ///
    /// The cost is known: someone who said a single short line in a whole
    /// meeting is written under their neighbour. Inventing a second
    /// person in a note spoken by one is worse.
    public static func absorbFleetingVoices(
        spans: [SpeakerSpan],
        centroids: [String: [Float]],
        minSeconds: Double = fleetingVoiceSeconds
    ) -> (spans: [SpeakerSpan], centroids: [String: [Float]]) {
        var byVoice: [String: [SpeakerSpan]] = [:]
        for span in spans { byVoice[span.speakerId, default: []].append(span) }
        guard byVoice.count > 1 else { return (spans, centroids) }
        let fleeting = Set(byVoice.filter { _, stretches in
            stretches.count == 1 && stretches.reduce(0) { $0 + $1.endSec - $1.startSec } < minSeconds
        }.keys)
        // Never absorb everyone: with only fleeting voices, keep them.
        guard !fleeting.isEmpty, fleeting.count < byVoice.count else { return (spans, centroids) }

        let solid = spans.filter { !fleeting.contains($0.speakerId) }
        func nearest(to span: SpeakerSpan) -> String {
            solid.min { a, b in gap(a, span) < gap(b, span) }!.speakerId
        }
        let reassigned = spans.map { span -> SpeakerSpan in
            guard fleeting.contains(span.speakerId) else { return span }
            return SpeakerSpan(speakerId: nearest(to: span), startSec: span.startSec, endSec: span.endSec)
        }
        var relabel: [String: String] = [:]
        var next = 0
        for span in reassigned.sorted(by: { $0.startSec < $1.startSec }) where relabel[span.speakerId] == nil {
            relabel[span.speakerId] = String(UnicodeScalar(UInt8(65 + min(next, 25))))
            next += 1
        }
        let outSpans = reassigned.map { SpeakerSpan(speakerId: relabel[$0.speakerId]!, startSec: $0.startSec, endSec: $0.endSec) }
        var outCentroids: [String: [Float]] = [:]
        for (id, label) in relabel { if let c = centroids[id] { outCentroids[label] = c } }
        return (outSpans, outCentroids)
    }

    /// Seconds between two stretches; 0 when they touch or overlap.
    private static func gap(_ a: SpeakerSpan, _ b: SpeakerSpan) -> Double {
        max(0, max(a.startSec, b.startSec) - min(a.endSec, b.endSec))
    }

    /// Names given to one diarization, carried to another of the same
    /// audio (25.09). The phone diarizes and the person names voices
    /// there; when the Mac later re-diarizes the same recording its
    /// clusters get fresh letters, and the names used to be lost. Each
    /// named voice goes to the new cluster whose centroid is closest,
    /// above `threshold`, closest pair first, one to one. Aliases
    /// (`Remote B`) are not names and are not carried.
    public static func carryNames(
        _ names: [String: String],
        from oldCentroids: [String: [Float]],
        to newCentroids: [String: [Float]],
        threshold: Float = ownerMatchThreshold
    ) -> [String: String] {
        var pairs: [(old: String, new: String, score: Float)] = []
        for (oldLabel, name) in names where !name.isEmpty && SpeakerMapping.aliasedLabel(name) == nil {
            guard let a = oldCentroids[oldLabel] else { continue }
            for (newLabel, b) in newCentroids {
                let score = cosine(a, b)
                if score >= threshold { pairs.append((oldLabel, newLabel, score)) }
            }
        }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.old, $0.new) < ($1.old, $1.new) }
        var usedOld = Set<String>(), usedNew = Set<String>()
        var out: [String: String] = [:]
        for pair in pairs where !usedOld.contains(pair.old) && !usedNew.contains(pair.new) {
            out[pair.new] = names[pair.old]
            usedOld.insert(pair.old)
            usedNew.insert(pair.new)
        }
        return out
    }

    public struct RoomResult: Sendable, Equatable {
        public var segments: [TranscriptSegment]
        /// The other voices' centroids, under their final labels.
        public var centroids: [String: [Float]]
        public var ownerCluster: String?
        public var ownerScore: Float
    }

    /// §3.6 for a recording whose microphone is the room: the cluster
    /// closest to the owner's profile (above the threshold) is the
    /// owner — their lines render under the display name — and every
    /// other voice is Remote A, B… in order of first appearance. With
    /// no profile, or none close enough, every voice is Remote.
    public static func assignRoom(
        segments: [TranscriptSegment],
        centroids: [String: [Float]],
        owner: [Float]?,
        threshold: Float = ownerMatchThreshold
    ) -> RoomResult {
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
                let score = cosine(owner, centroid)
                if score > ownerScore { ownerScore = score; ownerCluster = id }
            }
            if ownerScore < threshold { ownerCluster = nil }
        }

        var relabel: [String: String] = [:]
        var next = 0
        for id in order where id != ownerCluster {
            relabel[id] = String(UnicodeScalar(UInt8(65 + next % 26)))
            next += 1
        }
        let out: [TranscriptSegment] = segments.map { segment in
            var copy = segment
            if let id = segment.speakerId, id == ownerCluster {
                copy.source = .microphone
                copy.speakerId = nil
            } else {
                copy.source = .systemAudio
                copy.speakerId = segment.speakerId.flatMap { relabel[$0] }
            }
            return copy
        }
        var remote: [String: [Float]] = [:]
        for (id, centroid) in centroids { if let label = relabel[id] { remote[label] = centroid } }
        return RoomResult(segments: out, centroids: remote, ownerCluster: ownerCluster, ownerScore: ownerScore)
    }
}
