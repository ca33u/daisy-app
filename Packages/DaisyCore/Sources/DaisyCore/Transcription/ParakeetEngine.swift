//
//  ParakeetEngine.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/ParakeetEngine.swift (macOS Daisy
//  1.0.7.72, 2026-09-19) and cut down to the batch path: `load()`,
//  `transcribe(samples:)` with timecodes, the `idle / loading / ready /
//  failed` state with `lastFailureAt` and the 5-minute failure backoff.
//  Gone: the dictation gate, `NetworkMonitor` / `FluidAudioNetworkGuard`
//  (download lives in `ModelStore` now), the FluidAudio cache-dir
//  helpers (the model directory is explicit).
//
//  API note (FluidAudio 0.15.x @ 6428e29): the explicit
//  `transcribe(_ samples:decoderState:)` form with a fresh
//  `TdtDecoderState` per call — one-shot batch, no cross-call streaming
//  context. `ASRResult.tokenTimings` carries per-token start/end, which
//  `segments(from:)` groups into transcript segments at pauses.
//

import Foundation
import Observation
import os
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
@Observable
public final class ParakeetEngine: Transcribing {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var state: LoadState = .idle {
        didSet { if case .failed = state { lastFailureAt = Date() } }
    }
    /// When the last load attempt ended in `.failed`. A model that
    /// failed a minute ago is not going to succeed now.
    public private(set) var lastFailureAt: Date?
    public static let failureBackoff: TimeInterval = 5 * 60

    #if canImport(FluidAudio)
    @ObservationIgnored private var manager: AsrManager?
    #endif
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Parakeet")
    /// Where the model is. Set once; `ModelStore.directory`.
    public let modelDirectory: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public var isReady: Bool {
        if case .ready = state {
            #if canImport(FluidAudio)
            return manager != nil
            #else
            return false
            #endif
        }
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
        #if canImport(FluidAudio)
        if case .ready = state, manager != nil { return }
        if shouldSkipLoad { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
        #endif
    }

    /// Drop the loaded model (memory pressure, model removed).
    public func unload() {
        #if canImport(FluidAudio)
        manager = nil
        #endif
        state = .idle
    }

    #if canImport(FluidAudio)
    private func performLoad() async {
        if case .ready = state, manager != nil { return }
        state = .loading
        let dir = modelDirectory
        log.info("Parakeet: loading v3 from \(dir.lastPathComponent, privacy: .public)…")
        do {
            let models = try await AsrModels.load(from: dir, version: .v3)
            self.manager = AsrManager(config: .default, models: models)
            state = .ready
            log.info("Parakeet ASR ready (v3)")
        } catch {
            self.manager = nil
            if error is CancellationError || Task.isCancelled {
                state = .idle
                return
            }
            state = .failed(error.localizedDescription)
            log.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Transcribe 16 kHz mono Float samples → timed segments. Throws if
    /// the engine isn't available or the clip is too short (FluidAudio
    /// rejects sub-~0.3 s audio). Fresh decoder state per call.
    public func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        #if canImport(FluidAudio)
        await load()
        guard let manager else { throw ParakeetEngineError.notReady }
        var decoderState = TdtDecoderState.make()   // 2 LSTM layers (v2/v3)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let timings = (result.tokenTimings ?? []).map {
            Timing(token: $0.token, start: $0.startTime, end: $0.endTime)
        }
        return Self.segments(text: result.text, timings: timings, origin: Date())
        #else
        throw ParakeetEngineError.notReady
        #endif
    }

    // MARK: - Segmenting

    public struct Timing: Sendable, Equatable {
        public var token: String
        public var start: TimeInterval
        public var end: TimeInterval
        public init(token: String, start: TimeInterval, end: TimeInterval) {
            self.token = token
            self.start = start
            self.end = end
        }
    }

    /// Group token timings into segments: a new segment starts after a
    /// pause of `pause` seconds or once a segment runs `maxLength`
    /// seconds and a word boundary comes up. Without timings the whole
    /// text is one segment at 0:00. SentencePiece's `▁` marks a word
    /// start; it becomes a space.
    public nonisolated static func segments(
        text: String,
        timings: [Timing],
        origin: Date,
        pause: TimeInterval = 0.8,
        maxLength: TimeInterval = 30
    ) -> [TranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timings.isEmpty else {
            return trimmed.isEmpty ? [] : [TranscriptSegment(startedAt: origin, text: trimmed, startSec: 0, endSec: 0)]
        }
        var out: [TranscriptSegment] = []
        var current = ""
        var segStart = timings[0].start
        var lastEnd = timings[0].start
        func flush(endingAt end: TimeInterval) {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                out.append(TranscriptSegment(
                    startedAt: origin.addingTimeInterval(segStart),
                    text: t, startSec: segStart, endSec: end
                ))
            }
            current = ""
        }
        for timing in timings {
            let piece = timing.token.replacingOccurrences(of: "▁", with: " ")
            let startsWord = timing.token.hasPrefix("▁") || timing.token.hasPrefix(" ")
            let gap = timing.start - lastEnd
            let tooLong = timing.start - segStart >= maxLength
            if !current.isEmpty, startsWord, gap >= pause || tooLong {
                flush(endingAt: lastEnd)
                segStart = timing.start
            }
            current += piece
            lastEnd = max(lastEnd, timing.end)
        }
        flush(endingAt: lastEnd)
        return out
    }
}

public nonisolated enum ParakeetEngineError: LocalizedError {
    case notReady
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .notReady: return "Parakeet ASR isn’t available yet."
        case .unavailable: return "Parakeet ASR isn’t built into this binary."
        }
    }
}
