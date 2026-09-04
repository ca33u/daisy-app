//
//  NemotronLiveEngine.swift
//  Daisy
//
//  EXPERIMENTAL live-preview ASR for DICTATION — FluidAudio's Nemotron
//  3.5 Streaming Multilingual 0.6B (CoreML / Apple Neural Engine, 40
//  locales, 560 ms chunks = the lowest-latency tier). When
//  `AppSettings.dictationUseNemotronLive` is ON, dictation's live
//  transcript line streams from this engine instead of the Whisper
//  rolling-window pass — partials land ~0.6 s behind speech instead of
//  the 2 s re-decode cadence. The FINAL pasted text is unchanged: still
//  the one-shot Whisper (or Parakeet) pass on hotkey release, so paste
//  quality keeps its soak-tested engine while the preview gets fast.
//
//  Ships DARK (default OFF), same playbook as Parakeet (b54):
//    defaults write app.essazanov.Daisy daisy.dictationUseNemotronLive -bool YES
//  First enable downloads the multilingual 560 ms variant through
//  FluidAudioNetworkGuard's explicit download window; cached loads run
//  with FluidAudio's network hard-blocked (ModelHub.offlineMode).
//
//  Always loads the full-vocab `multilingual` variant (covers RU + 100+
//  languages); the per-session language hint goes through
//  `setLanguage(_:)` → the encoder's prompt_id, so ONE cached model
//  serves every dictation locale (no latin/multilingual cache split).
//

import Foundation
import Observation
import os
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
@Observable
final class NemotronLiveEngine {
    enum LoadState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    static let shared = NemotronLiveEngine()

    private(set) var state: LoadState = .notLoaded

    #if canImport(FluidAudio)
    @ObservationIgnored
    private var manager: StreamingNemotronMultilingualAsrManager?
    #endif
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    /// FIFO feed for the current session. A single consumer task awaits
    /// `process(samples:)` chunk-by-chunk so audio enters the streaming
    /// actor strictly in order — a Task-per-chunk would have no ordering
    /// guarantee across separate task hops.
    @ObservationIgnored
    private var feed: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored
    private var consumer: Task<Void, Never>?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "NemotronLive")

    private init() {}

    var isReady: Bool {
        if case .ready = state {
            #if canImport(FluidAudio)
            return manager != nil
            #else
            return false
            #endif
        }
        return false
    }

    /// Idempotent download + load of the multilingual / 560 ms variant.
    /// Concurrent callers await the same in-flight load. Non-throwing —
    /// failures land in `state = .failed` and `beginSession` returns false.
    func ensureLoaded() async {
        #if canImport(FluidAudio)
        if case .ready = state, manager != nil { return }
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

    #if canImport(FluidAudio)
    private func performLoad() async {
        if case .ready = state, manager != nil { return }
        state = .downloading(progress: 0)
        log.info("Nemotron live: downloading/loading multilingual 560 ms variant…")
        do {
            let load: @MainActor () async throws -> SharedNemotronMultilingualModels = {
                try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                    languageCode: "auto",  // full-vocab multilingual — one cache for all locales
                    chunkMs: 560,          // lowest-latency tier; dictation is latency-first
                    progressHandler: { progress in
                        // Strong capture on purpose: the engine is a
                        // process-lifetime singleton (`.shared`), so a
                        // weak dance buys nothing — and any [weak self]
                        // here just trips Xcode 26's mismatch warning
                        // against the enclosing `load` closure, which
                        // would implicitly capture self strongly anyway.
                        // FluidAudio releases the handler when
                        // downloadAndPreloadShared returns.
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            if case .ready = self.state { return }
                            self.state = .downloading(progress: fraction)
                        }
                    }
                )
            }
            // Offline-first: a cached variant loads with FluidAudio's
            // network hard-blocked; the first enable opens an explicit,
            // logged download window. See FluidAudioNetworkGuard.
            let shared: SharedNemotronMultilingualModels
            do {
                shared = try await load()
            } catch let error where FluidAudioNetworkGuard.isOfflineRejection(error) {
                shared = try await FluidAudioNetworkGuard.withDownloadsAllowed("Nemotron streaming ASR") {
                    try await load()
                }
            }
            state = .loading
            let m = StreamingNemotronMultilingualAsrManager()
            try await m.loadFromShared(shared)
            self.manager = m
            state = .ready
            log.info("Nemotron live engine ready (multilingual, 560 ms chunks)")
        } catch {
            self.manager = nil
            state = .failed(error.localizedDescription)
            log.error("Nemotron live load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Start one dictation session. Returns `false` when the engine can't
    /// run (model not downloaded / load failed) so the caller can fall
    /// back to the Whisper live path. `onRunningText` fires on the
    /// MainActor with the FULL running transcript after each decoded
    /// chunk (Nemotron partials are running text, not deltas).
    func beginSession(
        languageCode: String?,
        onRunningText: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        #if canImport(FluidAudio)
        await ensureLoaded()
        guard isReady, let manager else { return false }
        endSession()  // defensive: tear down any straggler feed

        await manager.reset()
        await manager.setLanguage(languageCode)
        await manager.setPartialCallback { text in
            Task { @MainActor in onRunningText(text) }
        }

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        feed = continuation
        let log = self.log
        consumer = Task {
            for await chunk in stream {
                if Task.isCancelled { break }
                do {
                    _ = try await manager.process(samples: chunk)
                } catch is CancellationError {
                    // The session ended mid-chunk — that's the key being
                    // released, not a failure. Logged as an error it
                    // appeared on every dictation and read as one.
                    break
                } catch {
                    log.error("Nemotron live process failed: \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
        }
        return true
        #else
        return false
        #endif
    }

    /// Feed 16 kHz mono samples (the Transcriber's already-converted
    /// chunks). Cheap — just enqueues onto the session's FIFO feed.
    func ingest(samples: [Float]) {
        feed?.yield(samples)
    }

    /// Stop feeding. The preview keeps whatever text it last showed; the
    /// authoritative pasted text comes from the one-shot final pass.
    func endSession() {
        feed?.finish()
        feed = nil
        consumer?.cancel()
        consumer = nil
    }
}
