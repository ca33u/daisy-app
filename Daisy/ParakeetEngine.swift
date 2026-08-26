//
//  ParakeetEngine.swift
//  Daisy
//
//  On-device Parakeet TDT v3 ASR (FluidAudio / CoreML / Apple Neural
//  Engine) — an EXPERIMENTAL alternative to WhisperEngine for the
//  dictation path only. FluidAudio is already a Daisy dependency
//  (diarization + Silero VAD), so this adds the ASR engine without a new
//  package: the library is linked, only the ~600 MB v3 model downloads on
//  first use. Parakeet is a streaming transducer (much lower decode
//  latency than Whisper's 30 s-window batch model) and covers 25 European
//  languages incl. Russian/Ukrainian.
//
//  Gated behind `AppSettings.dictationUseParakeet` (default OFF). Shipped
//  dark so we can A/B latency + RU quality on real dictation before
//  making it the default or adding a UI toggle. See the research note
//  2026-06-04-dictation-latency-optimization.
//
//  API note (FluidAudio 0.15.4): we deliberately drive the explicit
//  `transcribe(_ samples:decoderState:)` form with a fresh
//  `TdtDecoderState` per one-shot dictation (no cross-utterance
//  streaming context) rather than the convenience overloads. 0.15.x
//  also ships Nemotron 3.5 streaming ASR (40 locales, ANE) — a
//  candidate for a future LIVE dictation path — and
//  `ModelHub.offlineMode` for a hard no-network guarantee
//  once models are cached (not yet adopted; see backlog).
//

import Foundation
import Observation
import os
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
@Observable
final class ParakeetEngine {
    enum LoadState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    static let shared = ParakeetEngine()

    private(set) var state: LoadState = .notLoaded

    #if canImport(FluidAudio)
    @ObservationIgnored
    private var manager: AsrManager?
    #endif
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Parakeet")

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

    /// Idempotent load: download (first run only — ~600 MB for v3 int8) and
    /// initialize the `AsrManager`. Concurrent callers await the same
    /// in-flight load. Non-throwing — failures land in `state = .failed`
    /// and `transcribe` then throws `notReady`.
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
        // Don't flash `.downloading` (which surfaces as "Checking speech
        // models…") when the model is already on disk — only a real first
        // download should show download UI. A cached load shows `.loading`.
        let alreadyCached = Self.cachedModelCount() > 0
        state = alreadyCached ? .loading : .downloading(progress: 0)
        log.info("Parakeet: \(alreadyCached ? "loading" : "downloading") v3 (int8)…")
        do {
            // v3 = multilingual (incl. RU/UK). Default encoder precision is
            // int8; models cache on disk after the first download. The
            // progress handler is @Sendable + called off-main, so hop back
            // to MainActor to update observable state (drives the Settings
            // download bar). fractionCompleted spans download→compile 0…1.
            let load: @MainActor () async throws -> AsrModels = {
                try await AsrModels.downloadAndLoad(
                    version: .v3,
                    progressHandler: { progress in
                        // Strong capture on purpose: the engine is a
                        // process-lifetime singleton (`.shared`), so a
                        // weak dance buys nothing — and any [weak self]
                        // here just trips Xcode 26's mismatch warning
                        // against the enclosing `load` closure, which
                        // would implicitly capture self strongly anyway.
                        // FluidAudio releases the handler when
                        // downloadAndLoad returns.
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            if case .ready = self.state { return }
                            // Cached → stay on `.loading` (compile progress
                            // isn't a download); only a real fetch shows %.
                            self.state = alreadyCached ? .loading : .downloading(progress: fraction)
                        }
                    }
                )
            }
            // Offline-first: cached models load with FluidAudio's network
            // hard-blocked; a missing cache throws DownloadError and we
            // retry inside an explicit download window (first enable).
            let models: AsrModels
            do {
                models = try await load()
            } catch let error where FluidAudioNetworkGuard.isOfflineRejection(error) {
                models = try await FluidAudioNetworkGuard.withDownloadsAllowed("Parakeet v3 ASR") {
                    try await load()
                }
            }
            state = .loading
            // init(config:models:) wires the models in synchronously — the
            // actor reports `isAvailable == true` immediately after.
            self.manager = AsrManager(config: .default, models: models)
            state = .ready
            log.info("Parakeet ASR ready (v3)")
        } catch {
            self.manager = nil
            // Cancel (user pressed Stop) → clean .notLoaded, not .failed.
            if error is CancellationError || Task.isCancelled {
                state = .notLoaded
                log.info("Parakeet download cancelled")
                return
            }
            // Offline → clear message + auto-retry when the network returns.
            if NetworkMonitor.isOfflineError(error) || FluidAudioNetworkGuard.isOfflineRejection(error) {
                state = .failed(String(localized: "You’re offline — Daisy will finish downloading the dictation model automatically when you reconnect."))
                log.error("Parakeet download offline — will retry on reconnect")
                scheduleReloadOnReconnect()
                return
            }
            state = .failed(error.localizedDescription)
            log.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// One-shot auto-retry when the network returns (offline-at-launch heal).
    private func scheduleReloadOnReconnect() {
        NetworkMonitor.shared.runWhenOnline(id: "parakeet.reload") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = self.state { return }
                self.log.info("Network back — retrying Parakeet model load")
                await self.ensureLoaded()
            }
        }
    }

    /// Stop an in-progress Parakeet model download. Cancels the load task
    /// and resets state so the UI unblocks. No-op unless downloading.
    func cancelDownload() {
        guard case .downloading = state else { return }
        loadTask?.cancel()
        loadTask = nil
        state = .notLoaded
        log.info("Parakeet download cancelled by user")
    }

    /// Transcribe 16 kHz mono Float samples → trimmed text. Throws if the
    /// engine isn't available or the clip is too short (FluidAudio rejects
    /// sub-~0.3 s audio). Uses a fresh decoder state per call (one-shot
    /// batch transcription — no cross-utterance streaming context).
    func transcribe(samples: [Float]) async throws -> String {
        #if canImport(FluidAudio)
        await ensureLoaded()
        guard let manager else { throw ParakeetEngineError.notReady }
        var decoderState = TdtDecoderState.make()   // 2 LSTM layers (v2/v3)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw ParakeetEngineError.notReady
        #endif
    }

    // MARK: - On-disk cache (Settings → Transcription → Storage)

    #if canImport(FluidAudio)
    /// Bytes used by the Parakeet model on disk (0 if never downloaded).
    nonisolated static func cachedModelBytes() -> Int64 {
        fluidAudioParakeetDirs().reduce(0) { $0 + directorySize(at: $1) }
    }

    /// Number of cached Parakeet model folders (usually 0 or 1).
    nonisolated static func cachedModelCount() -> Int {
        fluidAudioParakeetDirs().count
    }

    /// Delete the cached Parakeet model(s) and drop the live engine so a
    /// future enable re-downloads. Returns freed bytes. Only the
    /// "parakeet" folders are touched — diarization / VAD models share the
    /// same FluidAudio cache root and must be left alone.
    @MainActor
    static func removeCachedModel() -> Int64 {
        var freed: Int64 = 0
        for dir in fluidAudioParakeetDirs() {
            let size = directorySize(at: dir)
            if (try? FileManager.default.removeItem(at: dir)) != nil { freed += size }
        }
        if freed > 0 {
            shared.manager = nil
            shared.state = .notLoaded
        }
        return freed
    }

    /// Parakeet folders under `~/Library/Application Support/FluidAudio/
    /// Models/` (FluidAudio's cache root — see ModelHub.clearAllCaches).
    /// Name-matched so we never touch the diarization / VAD
    /// models in the same root.
    private nonisolated static func fluidAudioParakeetDirs() -> [URL] {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return [] }
        let root = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir && url.lastPathComponent.lowercased().contains("parakeet")
        }
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true, let s = v?.fileSize { total += Int64(s) }
        }
        return total
    }
    #else
    nonisolated static func cachedModelBytes() -> Int64 { 0 }
    nonisolated static func cachedModelCount() -> Int { 0 }
    @MainActor static func removeCachedModel() -> Int64 { 0 }
    #endif
}

nonisolated enum ParakeetEngineError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return String(localized: "Parakeet ASR isn’t available yet.")
        }
    }
}
