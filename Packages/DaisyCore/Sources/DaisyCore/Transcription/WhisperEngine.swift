//
//  WhisperEngine.swift
//  DaisyCore
//
//  backlog 6 F-1: the phone's ONE transcription engine — WhisperKit with
//  `large-v3-v20240930_626MB`, the exact model id the Mac defaults to
//  (`Daisy/WhisperEngine.swift`, "Standard — fast, multilingual"). Same
//  model, same decoder, same knobs as the Mac's `.full` profile, so a
//  session recorded here and re-transcribed on the Mac reads the same.
//
//  Cut down from daisy-app/Daisy/WhisperEngine.swift (1.0.7.72,
//  2026-09-20): `load()` / `transcribe(samples:)`, the `idle / loading /
//  ready / failed` state with the 5-minute failure backoff. Gone: model
//  switching, dictation profiles, the bias prompt, the VAD pre-pass
//  (WhisperKit's own `.vad` chunking stays), the hallucination
//  post-filter beyond the two rules that matter for a batch pass (empty
//  text, exact repeat of the previous segment).
//
//  Model folder layout (what `ModelDownloader` lays down and
//  `ModelStore.verify` checks): the variant folder straight from
//  `argmaxinc/whisperkit-coreml` — `MelSpectrogram.mlmodelc`,
//  `AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `config.json`,
//  `generation_config.json` — plus the tokenizer in the hub layout
//  WhisperKit searches on its own: `models/openai/whisper-large-v3/
//  {config,tokenizer,tokenizer_config}.json`. Nothing is fetched at
//  load time (`download: false`); a missing file is a load failure, not
//  a surprise network call.
//

import Foundation
import Observation
import os
import WhisperKit

/// `WhisperKit` is a non-Sendable class; the decode runs off the main
/// actor, so the instance crosses isolation inside this box (same trick
/// as the Mac's `WhisperKitBox`).
private nonisolated final class KitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

@MainActor
@Observable
public final class WhisperEngine: Transcribing {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// What `daisy_transcription_model` says — the Mac's
    /// `WhisperEngine.defaultModelID`, character for character.
    public nonisolated static let modelID = "large-v3-v20240930_626MB"
    /// The variant folder in `argmaxinc/whisperkit-coreml`.
    public nonisolated static let modelRepo = "argmaxinc/whisperkit-coreml"
    public nonisolated static let variantFolderName = "openai_whisper-large-v3-v20240930_626MB"
    /// The tokenizer repo WhisperKit resolves for a large-v3 variant, and
    /// the relative folder it looks in under the model directory.
    public nonisolated static let tokenizerRepo = "openai/whisper-large-v3"
    public nonisolated static let tokenizerRelativePath = "models/openai/whisper-large-v3"
    public nonisolated static let tokenizerFiles: Set<String> = ["config.json", "tokenizer.json", "tokenizer_config.json"]
    public nonisolated static let requiredModelItems: Set<String> = [
        "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
    ]

    public private(set) var state: LoadState = .idle {
        didSet { if case .failed = state { lastFailureAt = Date() } }
    }
    /// When the last load attempt ended in `.failed`. A model that
    /// failed a minute ago is not going to succeed now.
    public private(set) var lastFailureAt: Date?
    public nonisolated static let failureBackoff: TimeInterval = 5 * 60
    /// Seconds the last `load()` took (diagnostics; the first load on a
    /// device compiles for the Neural Engine and can run minutes).
    public private(set) var lastLoadSeconds: Double?

    @ObservationIgnored private var box: KitBox?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Whisper")
    /// Where the model is. Set once; `ModelStore.directory`.
    public let modelDirectory: URL
    /// Base WhisperKit searches for `models/openai/whisper-large-v3/tokenizer.json`
    /// (and its top level). Defaults to the model directory.
    public let tokenizerDirectory: URL

    public init(modelDirectory: URL, tokenizerDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory
        self.tokenizerDirectory = tokenizerDirectory ?? modelDirectory
    }

    public var isReady: Bool {
        if case .ready = state { return box != nil }
        return false
    }

    /// True inside the backoff window after a failure.
    public var shouldSkipLoad: Bool {
        guard case .failed = state, let at = lastFailureAt else { return false }
        return Date().timeIntervalSince(at) < Self.failureBackoff
    }

    /// Idempotent load from `modelDirectory`. Concurrent callers await
    /// the same in-flight load. Non-throwing — failures land in
    /// `state = .failed` and `transcribe` then throws `notReady`.
    public func load() async {
        if case .ready = state, box != nil { return }
        if shouldSkipLoad { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Drop the loaded model (memory pressure, model removed).
    public func unload() {
        if let box {
            Task.detached { await box.kit.unloadModels() }
        }
        box = nil
        state = .idle
    }

    private func performLoad() async {
        if case .ready = state, box != nil { return }
        state = .loading
        let folder = modelDirectory
        let tokenizerFolder = tokenizerDirectory
        let started = Date()
        log.info("Whisper: loading \(Self.modelID, privacy: .public) from \(folder.lastPathComponent, privacy: .public)…")
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> KitBox in
                let config = WhisperKitConfig(
                    modelFolder: folder.path,
                    tokenizerFolder: tokenizerFolder,
                    verbose: false,
                    logLevel: .error,
                    prewarm: false,
                    load: true,
                    download: false
                )
                return KitBox(try await WhisperKit(config))
            }.value
            box = loaded
            lastLoadSeconds = Date().timeIntervalSince(started)
            state = .ready
            log.info("Whisper ready in \(Int(self.lastLoadSeconds ?? 0), privacy: .public) s")
        } catch {
            box = nil
            if error is CancellationError || Task.isCancelled {
                state = .idle
                return
            }
            state = .failed(error.localizedDescription)
            log.error("Whisper load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Transcribe

    /// One pass over a whole recording.
    public nonisolated struct Transcription: Sendable, Equatable {
        public var segments: [TranscriptSegment]
        /// ISO 639-1 code Whisper settled on (`ru`, `en`, …); nil when the
        /// pass produced nothing.
        public var language: String?
        /// Decode wall time / audio length — the number the backlog wants
        /// from the real phone.
        public var realTimeFactor: Double
        public init(segments: [TranscriptSegment], language: String?, realTimeFactor: Double) {
            self.segments = segments
            self.language = language
            self.realTimeFactor = realTimeFactor
        }
    }

    /// `Transcribing` — segments only.
    public func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        try await run(samples: samples).segments
    }

    /// Transcribe 16 kHz mono Float samples → timed segments plus the
    /// detected language. Auto-detects the language (the Mac's `auto`),
    /// the `.full` profile's knobs otherwise. Throws if the engine isn't
    /// available.
    public func run(samples: [Float]) async throws -> Transcription {
        await load()
        guard let box else { throw WhisperEngineError.notReady }
        guard Double(samples.count) / 16_000 >= 0.2 else {
            return Transcription(segments: [], language: nil, realTimeFactor: 0)
        }
        let origin = Date()
        let started = Date()
        let raw = try await Task.detached(priority: .userInitiated) { () throws -> RawPass in
            // The Mac's `DecodeProfile.full`, minus the bias prompt.
            // `concurrentWorkerCount` 4, not the Mac's 16: a phone has
            // one Neural Engine and a sixth of the memory.
            let options = DecodingOptions(
                task: .transcribe,
                language: nil,
                temperatureFallbackCount: 3,
                topK: 5,
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.4,
                concurrentWorkerCount: 4,
                chunkingStrategy: .vad
            )
            let results = try await box.kit.transcribe(audioArray: samples, decodeOptions: options)
            var segments: [RawSegment] = []
            var language: String?
            for result in results {
                if language == nil, !result.language.isEmpty { language = result.language }
                for s in result.segments {
                    segments.append(RawSegment(start: Double(s.start), end: Double(s.end), text: s.text))
                }
            }
            return RawPass(segments: segments, language: language)
        }.value
        let decodeSeconds = Date().timeIntervalSince(started)
        let audioSeconds = Double(samples.count) / 16_000
        let segments = Self.segments(from: raw.segments, origin: origin)
        let rtf = audioSeconds > 0 ? decodeSeconds / audioSeconds : 0
        log.info("Whisper pass: \(Int(audioSeconds), privacy: .public) s audio in \(Int(decodeSeconds), privacy: .public) s (RTF \(String(format: "%.2f", rtf), privacy: .public)), \(segments.count, privacy: .public) segments, language \(raw.language ?? "-", privacy: .public)")
        return Transcription(segments: segments, language: segments.isEmpty ? nil : raw.language, realTimeFactor: rtf)
    }

    // MARK: - Segments

    public nonisolated struct RawSegment: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    private nonisolated struct RawPass: Sendable {
        var segments: [RawSegment]
        var language: String?
    }

    /// WhisperKit segments → transcript segments. Sorted by start; empty
    /// text and an exact repeat of the previous segment (the classic
    /// Whisper loop) are dropped — the two post-filter rules from the
    /// Mac that apply to a batch pass.
    public nonisolated static func segments(from raw: [RawSegment], origin: Date) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var previous: String?
        for s in raw.sorted(by: { $0.start < $1.start }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous, previous == text { continue }
            previous = text
            out.append(TranscriptSegment(
                startedAt: origin.addingTimeInterval(s.start),
                text: text,
                startSec: s.start,
                endSec: max(s.end, s.start)
            ))
        }
        return out
    }
}

public nonisolated enum WhisperEngineError: LocalizedError {
    case notReady
    public var errorDescription: String? {
        switch self {
        case .notReady: return "Whisper isn’t available yet."
        }
    }
}
