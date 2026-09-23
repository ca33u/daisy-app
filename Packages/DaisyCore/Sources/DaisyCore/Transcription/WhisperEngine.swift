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
//  post-filter beyond the rules that matter for a batch pass (empty
//  text, exact repeat of the previous segment, a line that loops —
//  `RepetitionLoop`, 2026-09-23).
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
    /// Seconds the post-load warm-up decode took.
    public private(set) var lastWarmUpSeconds: Double?

    /// Load progress for the UI. Core ML gives no progress inside one
    /// model's compilation, but the load has four stages of known
    /// weight (by bytes: mel 0.4 MB, text decoder 203 MB, audio encoder
    /// 423 MB, tokenizer); WhisperKit announces each boundary in its
    /// log, which `stageObserver` reads. Inside a stage the bar moves
    /// with the clock against that stage's duration LAST time (kept in
    /// UserDefaults), so a warm start fills in seconds and a cold one
    /// in minutes — both honest, neither stuck at 0.
    public nonisolated struct LoadProgress: Sendable, Equatable {
        public var fraction: Double = 0
        public var stage: String = "Preparing…"
        public var elapsedSeconds: Int = 0
        /// How long the whole load took last time, if known.
        public var lastTotalSeconds: Int?
    }
    public private(set) var loadProgress = LoadProgress()

    private nonisolated struct Stage: Sendable {
        let marker: String      // WhisperKit log line that starts it
        let name: String
        let from: Double        // fraction at start
        let to: Double          // fraction at end
        let key: String         // UserDefaults key for its last duration
        let defaultSeconds: Double
    }
    private nonisolated static let stages: [Stage] = [
        Stage(marker: "Loading feature extractor", name: "Mel spectrogram", from: 0.00, to: 0.03, key: "mel", defaultSeconds: 2),
        Stage(marker: "Loading text decoder", name: "Text decoder (203 MB)", from: 0.03, to: 0.35, key: "decoder", defaultSeconds: 40),
        Stage(marker: "Loading audio encoder", name: "Audio encoder (423 MB)", from: 0.35, to: 0.95, key: "encoder", defaultSeconds: 90),
        Stage(marker: "Loading tokenizer", name: "Tokenizer", from: 0.95, to: 1.00, key: "tokenizer", defaultSeconds: 2),
    ]
    private nonisolated static let stageDefaultsPrefix = "daisy.whisper.loadStageSeconds."
    private nonisolated static let totalDefaultsKey = "daisy.whisper.loadTotalSeconds"
    @ObservationIgnored private var stageIndex = -1
    @ObservationIgnored private var stageStartedAt = Date()
    @ObservationIgnored private var progressTicker: Task<Void, Never>?

    @ObservationIgnored private var box: KitBox?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// One decode at a time: the finishing pass and the live preview
    /// (backlog 6 F-3) share this instance, and WhisperKit isn't
    /// reentrant. Same shape as the Mac's in-actor semaphore.
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
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

    // MARK: - Load progress

    private func beginProgress(startedAt: Date) {
        stageIndex = -1
        stageStartedAt = startedAt
        let lastTotal = UserDefaults.standard.double(forKey: Self.totalDefaultsKey)
        loadProgress = LoadProgress(fraction: 0, stage: "Preparing…", elapsedSeconds: 0,
                                    lastTotalSeconds: lastTotal > 0 ? Int(lastTotal.rounded()) : nil)
        // WhisperKit's log is the only place the stage boundaries show.
        Logging.shared.loggingCallback = { [weak self] message in
            guard let index = Self.stages.firstIndex(where: { message.contains($0.marker) }) else { return }
            Task { @MainActor [weak self] in self?.enterStage(index) }
        }
        progressTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tickProgress(startedAt: startedAt)
            }
        }
    }

    private func enterStage(_ index: Int) {
        guard index > stageIndex else { return }
        // Close the stage we were in: remember how long it took.
        if stageIndex >= 0 {
            let stage = Self.stages[stageIndex]
            UserDefaults.standard.set(Date().timeIntervalSince(stageStartedAt), forKey: Self.stageDefaultsPrefix + stage.key)
        }
        stageIndex = index
        stageStartedAt = Date()
        loadProgress.stage = Self.stages[index].name
        loadProgress.fraction = Self.stages[index].from
    }

    private func tickProgress(startedAt: Date) {
        loadProgress.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
        guard stageIndex >= 0 else { return }
        let stage = Self.stages[stageIndex]
        let stored = UserDefaults.standard.double(forKey: Self.stageDefaultsPrefix + stage.key)
        let expected = stored > 0 ? stored : stage.defaultSeconds
        let inStage = min(0.97, Date().timeIntervalSince(stageStartedAt) / expected)
        loadProgress.fraction = max(loadProgress.fraction, stage.from + (stage.to - stage.from) * inStage)
    }

    private func endProgress(startedAt: Date, succeeded: Bool) {
        progressTicker?.cancel()
        progressTicker = nil
        Logging.shared.loggingCallback = nil
        Logging.shared.logLevel = .error
        if succeeded {
            if stageIndex >= 0 {
                UserDefaults.standard.set(Date().timeIntervalSince(stageStartedAt), forKey: Self.stageDefaultsPrefix + Self.stages[stageIndex].key)
            }
            UserDefaults.standard.set(Date().timeIntervalSince(startedAt), forKey: Self.totalDefaultsKey)
            loadProgress.fraction = 1
            loadProgress.stage = "Ready"
        }
        loadProgress.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
    }

    /// The Mac's `warmUpIfNeeded`: one second of silence through the
    /// decoder right after the load, off the critical path, so the
    /// first REAL decode (the live sheet's first window, the finishing
    /// pass) doesn't pay the decoder's own first-run specialization.
    /// Goes through the slot like any pass, so it never overlaps one.
    private func warmUp() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            _ = try? await run(samples: [Float](repeating: 0, count: 16_000), profile: .live, language: "en")
            lastWarmUpSeconds = Date().timeIntervalSince(started)
            log.info("Whisper warm-up: \(String(format: "%.1f", self.lastWarmUpSeconds ?? 0), privacy: .public) s")
        }
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
        beginProgress(startedAt: started)
        IntentBreadcrumb.log("Whisper load begin")
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> KitBox in
                let config = WhisperKitConfig(
                    modelFolder: folder.path,
                    tokenizerFolder: tokenizerFolder,
                    verbose: true,
                    logLevel: .debug,
                    prewarm: false,
                    load: true,
                    download: false
                )
                return KitBox(try await WhisperKit(config))
            }.value
            box = loaded
            lastLoadSeconds = Date().timeIntervalSince(started)
            endProgress(startedAt: started, succeeded: true)
            state = .ready
            log.info("Whisper ready in \(Int(self.lastLoadSeconds ?? 0), privacy: .public) s")
            IntentBreadcrumb.log("Whisper load done in \(Int(self.lastLoadSeconds ?? 0)) s")
            warmUp()
        } catch {
            endProgress(startedAt: started, succeeded: false)
            box = nil
            if error is CancellationError || Task.isCancelled {
                state = .idle
                return
            }
            state = .failed(error.localizedDescription)
            log.error("Whisper load failed: \(error.localizedDescription, privacy: .public)")
            IntentBreadcrumb.log("Whisper load FAILED: \(error.localizedDescription)")
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
        /// Word timings, seconds into the samples — only when asked for
        /// (rehearsal takes, §3.7); empty otherwise.
        public var words: [WordTiming] = []
        public init(segments: [TranscriptSegment], language: String?, realTimeFactor: Double, words: [WordTiming] = []) {
            self.segments = segments
            self.language = language
            self.realTimeFactor = realTimeFactor
            self.words = words
        }
    }

    /// `Transcribing` — segments only.
    public func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        try await run(samples: samples).segments
    }

    /// Which knobs a pass runs with — the Mac's `DecodeProfile`, two of
    /// its three: `.full` for the transcript that goes on disk, `.live`
    /// for the preview in the live sheet (backlog 6 F-3), where a
    /// second of latency matters more than a fallback retry.
    public nonisolated enum Profile: Sendable, Equatable {
        case full
        case live
        var temperatureFallbackCount: Int { self == .full ? 3 : 0 }
        var topK: Int { self == .full ? 5 : 1 }
        var chunking: ChunkingStrategy { self == .full ? .vad : .none }
    }

    private func acquireSlot() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Transcribe 16 kHz mono Float samples → timed segments plus the
    /// detected language. Auto-detects the language (the Mac's `auto`)
    /// unless `language` pins it. Throws if the engine isn't available.
    /// `onProgress` gets the fraction of the audio decoded so far (0…1),
    /// from WhisperKit's segment-discovery callback — for the system's
    /// continued-processing UI (backlog 7 A-1), which expires a task that
    /// looks stalled.
    public func run(
        samples: [Float], profile: Profile = .full, language: String? = nil,
        wordTimestamps: Bool = false,
        prompt: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcription {
        await load()
        guard let box else { throw WhisperEngineError.notReady }
        guard Double(samples.count) / 16_000 >= 0.2 else {
            return Transcription(segments: [], language: nil, realTimeFactor: 0)
        }
        await acquireSlot()
        defer { releaseSlot() }
        let origin = Date()
        let started = Date()
        let raw = try await Task.detached(priority: .userInitiated) { () throws -> RawPass in
            // The Mac's `DecodeProfile`, minus the bias prompt.
            // `concurrentWorkerCount` 4, not the Mac's 16: a phone has
            // one Neural Engine and a sixth of the memory.
            //
            // DECISION (backlog 7 A-3, Egor, 2026-09-20): the temperature
            // fallback STAYS. It is stochastic — a segment that fails the
            // logprob / compression thresholds is re-decoded at a higher
            // temperature, so two passes over the same mumbled audio can
            // differ by a few words, even on one machine (seen 2026-09-20:
            // phone, Mac app and this class on the Mac all disagreed on a
            // 20-second mumble, agreed word for word on clear speech).
            // That is the price of not printing a hallucinated repeat
            // loop into the transcript, which is worse. Do not "fix" the
            // nondeterminism by setting temperatureFallbackCount to 0.
            // An optional conditioning prompt — for rehearsal takes, an
            // example of hesitant speech so the model keeps «э», «эм»
            // instead of cleaning them away (backlog 17 С-4). NEVER the
            // script: a model told what should be said hears it (§3.7).
            var promptTokens: [Int]?
            if let prompt, !prompt.isEmpty, let tokenizer = box.kit.tokenizer {
                let encoded = tokenizer.encode(text: " " + prompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                promptTokens = Array(encoded.prefix(200))
            }
            let options = DecodingOptions(
                task: .transcribe,
                language: language,
                temperatureFallbackCount: profile.temperatureFallbackCount,
                topK: profile.topK,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: wordTimestamps,
                promptTokens: promptTokens,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.4,
                concurrentWorkerCount: 4,
                chunkingStrategy: profile.chunking
            )
            let audioSeconds = Double(samples.count) / 16_000
            var segmentCallback: SegmentDiscoveryCallback?
            if let report = onProgress {
                segmentCallback = { (segments: [TranscriptionSegment]) in
                    guard let last = segments.map(\.end).max() else { return }
                    report(min(1, Double(last) / audioSeconds))
                }
            }
            let results = try await box.kit.transcribe(
                audioArray: samples, decodeOptions: options, segmentCallback: segmentCallback
            )
            var segments: [RawSegment] = []
            var words: [WordTiming] = []
            var language: String?
            for result in results {
                if language == nil, !result.language.isEmpty { language = result.language }
                for s in result.segments {
                    segments.append(RawSegment(start: Double(s.start), end: Double(s.end), text: s.text))
                    // Words as heard. They are asked for on rehearsal
                    // takes only — speech read aloud, where the loop
                    // shapes that guard meetings from silence don't arise.
                    for w in s.words ?? [] {
                        let text = w.word.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }
                        words.append(WordTiming(w: text, s: Double(w.start), e: Double(w.end)))
                    }
                }
            }
            return RawPass(segments: segments, language: language, words: words)
        }.value
        let decodeSeconds = Date().timeIntervalSince(started)
        let audioSeconds = Double(samples.count) / 16_000
        let segments = Self.segments(from: raw.segments, origin: origin)
        let rtf = audioSeconds > 0 ? decodeSeconds / audioSeconds : 0
        log.info("Whisper pass: \(Int(audioSeconds), privacy: .public) s audio in \(Int(decodeSeconds), privacy: .public) s (RTF \(String(format: "%.2f", rtf), privacy: .public)), \(segments.count, privacy: .public) segments, language \(raw.language ?? "-", privacy: .public)")
        return Transcription(segments: segments, language: segments.isEmpty ? nil : raw.language, realTimeFactor: rtf,
                             words: raw.words.sorted { $0.s < $1.s })
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
        var words: [WordTiming] = []
    }

    /// WhisperKit segments → transcript segments. Sorted by start; empty
    /// text, an exact repeat of the previous segment and a line that is
    /// one phrase repeating (`RepetitionLoop.isLoop`) are dropped — the
    /// post-filter rules from the Mac that one pass can judge. Loops
    /// spread over several lines are the caller's, where blocks join.
    public nonisolated static func segments(from raw: [RawSegment], origin: Date) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var previous: String?
        for s in raw.sorted(by: { $0.start < $1.start }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous, previous == text { continue }
            // One phrase going round («я знаю, что я знаю…»): the shape
            // silence makes, whatever the words (Mac incident, 23.09).
            if RepetitionLoop.isLoop(text) { continue }
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
