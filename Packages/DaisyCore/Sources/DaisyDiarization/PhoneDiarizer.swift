//
//  PhoneDiarizer.swift
//  DaisyCore
//
//  Бэклог 18: does the phone separate voices the way the Mac does?
//
//  This is a SPIKE, and the file is shaped like one: it measures and
//  reports, it does not decide. Nothing here writes `daisy_speaker_map`
//  — while the Mac is the one that diarizes phone sessions, a second
//  set of labels travelling through sync would just argue with the
//  first (Д-5). The result goes to a local file that does not sync.
//
//  Copied from daisy-app/Daisy/DiarizationEngine.swift @ 1.0.8.1,
//  2026-09-23 — the configuration numbers especially. They are not
//  defaults and not taste: a different clustering threshold gives a
//  different number of speakers on the same audio, and then a phone/Mac
//  disagreement would say nothing about the phone.
//

import DaisyCore
import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

/// One stretch of one voice.
/// The spike's name for a voice's stretch; the shared type now.
public typealias DiarizedSpan = SpeakerSpan

public struct DiarizationOutcome: Sendable, Equatable, Codable {
    public var spans: [DiarizedSpan]
    /// Average 256-d embedding per speaker, L2-normalised — the thing a
    /// `SpeakerProfile` would be compared against, if the phone had one.
    public var centroids: [String: [Float]]
    public var seconds: Double

    public nonisolated var speakerCount: Int { Set(spans.map(\.speakerId)).count }
}

public enum PhoneDiarizerError: Error, LocalizedError {
    case unavailable
    case tooShort

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Diarization is not built into this build."
        case .tooShort: return "The recording is too short to separate voices."
        }
    }
}

@MainActor
public final class PhoneDiarizer {
    /// The Mac's numbers, copied deliberately. `numClusters: -1` means
    /// "decide how many people there are"; pinning it would make the
    /// count an input rather than a measurement.
    public nonisolated static let clusteringThreshold: Float = 0.7
    public nonisolated static let minSpeechDuration: Float = 1.0
    public nonisolated static let minSilenceGap: Float = 0.5

    /// Below this there is nothing to cluster — the Mac uses the same
    /// floor, so a short file behaves identically on both.
    public nonisolated static let minimumSamples = 16_000 * 3

    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Diarization")

    #if canImport(FluidAudio)
    private var manager: DiarizerManager?
    /// Loaded once; each recording gets a manager of its own on them.
    private var models: DiarizerModels?
    #endif

    /// The clustering threshold this instance runs with. Defaults to
    /// the Mac's shipping value; a spike can sweep it to find where a
    /// single voice stops being split in two.
    private let threshold: Float

    public init(clusteringThreshold: Float = PhoneDiarizer.clusteringThreshold) {
        self.threshold = clusteringThreshold
    }

    /// Seconds the last `load()` took, and whether anything was
    /// downloaded — both go in the report.
    public private(set) var lastLoadSeconds: Double?
    public private(set) var isReady = false

    /// Downloads the models on first use, exactly as the Mac does — they
    /// are ~13 MB on disk (segmentation 5.5 + WeSpeaker 7.6 + two JSON
    /// tables), so they do not belong in the app bundle.
    public func load() async throws {
        #if canImport(FluidAudio)
        guard manager == nil else { return }
        let started = Date()
        let models = try await loadedModels()
        let manager = makeManager(models: models)
        self.manager = manager
        lastLoadSeconds = Date().timeIntervalSince(started)
        isReady = true
        log.info("Diarizer ready in \(Int(self.lastLoadSeconds ?? 0), privacy: .public) s")
        #else
        throw PhoneDiarizerError.unavailable
        #endif
    }

    #if canImport(FluidAudio)
    private func loadedModels() async throws -> DiarizerModels {
        if let models { return models }
        let loaded = try await DiarizerModels.downloadIfNeeded()
        models = loaded
        return loaded
    }

    private func makeManager(models: DiarizerModels) -> DiarizerManager {
        let config = DiarizerConfig(
            clusteringThreshold: threshold,
            minSpeechDuration: Self.minSpeechDuration,
            minSilenceGap: Self.minSilenceGap,
            numClusters: -1
        )
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        return manager
    }
    #endif

    /// A pass over one recording, block by block — with a speaker
    /// database of its own, so voices from the last recording never
    /// leak into this one.
    public func makeBlockPass() async throws -> DiarizationBlockPass {
        #if canImport(FluidAudio)
        let models = try await loadedModels()
        isReady = true
        return DiarizationBlockPass(manager: makeManager(models: models))
        #else
        throw PhoneDiarizerError.unavailable
        #endif
    }

    /// Give the memory back. The spike needs to know what the phone
    /// costs with Whisper resident and with Whisper gone, and that
    /// question is only answerable if both sides can be unloaded.
    public func unload() {
        #if canImport(FluidAudio)
        manager = nil
        models = nil
        #endif
        isReady = false
    }

    /// 16 kHz mono float samples in, voices out.
    public func run(samples: [Float]) async throws -> DiarizationOutcome {
        guard samples.count > Self.minimumSamples else { throw PhoneDiarizerError.tooShort }
        #if canImport(FluidAudio)
        if manager == nil { try await load() }
        guard let manager else { throw PhoneDiarizerError.unavailable }
        let result = try manager.performCompleteDiarization(samples)
        let labels = Self.labelMap(for: result.segments)
        let spans = result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .compactMap { segment -> DiarizedSpan? in
                guard let label = labels[segment.speakerId] else { return nil }
                return DiarizedSpan(speakerId: label,
                                    startSec: Double(segment.startTimeSeconds),
                                    endSec: Double(segment.endTimeSeconds))
            }
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for segment in result.segments {
            guard let label = labels[segment.speakerId] else { continue }
            let embedding = segment.embedding
            guard !embedding.isEmpty else { continue }
            if var running = sums[label] {
                for i in running.indices where i < embedding.count { running[i] += embedding[i] }
                sums[label] = running
            } else {
                sums[label] = embedding
            }
            counts[label, default: 0] += 1
        }
        var centroids: [String: [Float]] = [:]
        for (label, sum) in sums {
            let n = Float(counts[label] ?? 1)
            var mean = sum.map { $0 / n }
            // L2-normalised, like the Mac: cosine similarity against a
            // `SpeakerProfile` is a dot product only if both sides are.
            let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { mean = mean.map { $0 / norm } }
            centroids[label] = mean
        }
        return DiarizationOutcome(spans: spans, centroids: centroids,
                                  seconds: Double(samples.count) / 16_000)
        #else
        throw PhoneDiarizerError.unavailable
        #endif
    }

    #if canImport(FluidAudio)
    /// `Speaker_3` → `A`, in order of first appearance, so two runs of
    /// the same audio read the same way.
    private nonisolated static func labelMap(for segments: [TimedSpeakerSegment]) -> [String: String] {
        var map: [String: String] = [:]
        var next = 0
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            guard map[segment.speakerId] == nil else { continue }
            map[segment.speakerId] = String(UnicodeScalar(UInt8(65 + min(next, 25))))
            next += 1
        }
        return map
    }
    #endif
}
