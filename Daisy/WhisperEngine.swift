//
//  WhisperEngine.swift
//  Daisy
//
//  Singleton wrapper around WhisperKit (Argmax). Model download is split
//  from model load so the UI can show real progress. One CoreML instance
//  is shared between the mic + system-audio transcribers; concurrent
//  transcribe requests are serialized via an in-actor semaphore.
//

import Foundation
import Darwin
import Observation
import os
import WhisperKit
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
@Observable
final class WhisperEngine {
    enum LoadState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading(status: String)
        case ready
        case failed(String)
    }

    /// Catalog of CoreML-converted Whisper models on Argmax's HuggingFace
    /// repo (argmaxinc/whisperkit-coreml). IDs are short suffixes;
    /// WhisperKit prepends "openai_whisper-" internally when resolving
    /// HF folder names.
    ///
    /// `large-v3-v20240930` IS large-v3-turbo — Argmax keeps OpenAI's
    /// release-date naming (turbo was released 2024-09-30). The
    /// `_626MB` variant is mixed-bit quantized to ~626 MB while
    /// retaining ~99% of large-v3 accuracy — Argmax's officially
    /// recommended default for multilingual.
    /// Curated two-model lineup. Removed tiny/base/small/medium and
    /// large-v2 / large-v3-non-turbo to kill paradox-of-choice in
    /// Settings. Most users never benchmark themselves; we pick the
    /// sane defaults for them. Power users who genuinely need other
    /// sizes can be re-enabled via Advanced settings later if there's
    /// demand.
    static let availableModels: [(id: String, label: String, sizeMB: Int)] = [
        ("large-v3-v20240930_626MB", String(localized: "Standard — fast, multilingual (recommended)"),  626),
        ("large-v3-v20240930",       String(localized: "Highest accuracy — large-v3 turbo, full"),     1500),
    ]

    /// First-run default — `large-v3-v20240930_626MB`. 626 MB quantized
    /// turbo: multilingual (incl. RU), ~99% of large-v3 quality, lands
    /// total app footprint in the ~700 MB sweet spot Shadow hits.
    /// Existing installs keep whatever they previously picked.
    static let defaultModelID = "large-v3-v20240930_626MB"
    static let shared = WhisperEngine()

    var modelID: String {
        didSet {
            guard oldValue != modelID else { return }
            UserDefaults.standard.set(modelID, forKey: Self.modelKey)
            Task { await self.reload() }
        }
    }

    private(set) var state: LoadState = .notLoaded
    /// Progress 0.0–1.0 during the .downloading phase. Mirrors the value
    /// from .downloading associated value for binding-friendly UI.
    private(set) var downloadProgress: Double = 0
    /// Estimated 0.0–1.0 progress during CoreML specialization/loading.
    /// Core ML exposes no byte or unit callback for this phase, so Daisy
    /// advances a determinate estimate based on elapsed time and the last
    /// successful load of this model. It never reaches 100% until the model
    /// is actually ready.
    private(set) var loadProgress: Double = 0
    /// Wall-clock start of the CoreML load phase, retained for diagnostics.
    private(set) var loadStartedAt: Date?

    /// Disk/download size (MB) of the currently selected model — powers the
    /// "X / Y MB" download label. Falls back to the recommended default's
    /// size if the id isn't in the catalog.
    var activeModelSizeMB: Int {
        Self.availableModels.first { $0.id == modelID }?.sizeMB ?? 626
    }

    @ObservationIgnored
    private var kitBox: WhisperKitBox?
    /// Job-scoped model used by explicit re-transcription. Kept separate
    /// from `modelID` so choosing a model in the session sheet never
    /// changes the user's default meeting model or UserDefaults. Only one
    /// alternate is retained at a time and the batch service releases it
    /// when the derived session has been written.
    @ObservationIgnored
    private var alternateModelID: String?
    @ObservationIgnored
    private var alternateKitBox: WhisperKitBox?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadProgressTask: Task<Void, Never>?
    #if canImport(FluidAudio)
    /// Silero VAD wrapper, loaded lazily alongside Whisper. Used as a
    /// pre-pass on every `transcribe` call to gate out non-speech
    /// audio before it reaches Whisper — the biggest single lever
    /// against ambient-noise hallucinations (whisper.cpp #2286,
    /// faster-whisper #843). Nil while loading or if load failed;
    /// `transcribe` falls back to full-buffer Whisper in that case so
    /// the user never sees a hard error from VAD.
    @ObservationIgnored
    private var vadBox: VadManagerBox?
    @ObservationIgnored
    private var vadLoadTask: Task<Void, Never>?
    #endif

    // In-actor serialization for transcribe — WhisperKit isn't thread-safe
    // for simultaneous transcribes.
    @ObservationIgnored
    private var isBusy = false
    @ObservationIgnored
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// One-time post-load warm-up guard — see `warmUpIfNeeded()`.
    @ObservationIgnored
    private var didWarmUp = false

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Whisper")

    private static let modelKey = "daisy.whisperModelID"
    private static let loadDurationKeyPrefix = "daisy.whisperLoadDuration."

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModelID
        // Migration: strip old wrongly-prefixed format AND remap names
        // we used during research that don't exist in Argmax's repo.
        var cleaned = stored
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "openai-whisper-", with: "")
        // "large-v3-turbo" was our guess; the actual Argmax folder is
        // suffixed with the v20240930 turbo release date.
        if cleaned == "large-v3-turbo" || cleaned == "large-v3_turbo" {
            cleaned = "large-v3-v20240930"
        }
        let valid = Self.availableModels.map(\.id)
        if !valid.contains(cleaned) {
            cleaned = Self.defaultModelID
        }
        self.modelID = cleaned
        if cleaned != stored {
            UserDefaults.standard.set(cleaned, forKey: Self.modelKey)
        }
    }

    // MARK: - Lifecycle

    func ensureLoaded() async {
        if case .ready = state, kitBox != nil { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func reload() async {
        stopLoadProgressClock()
        kitBox = nil
        state = .notLoaded
        downloadProgress = 0
        loadProgress = 0
        await ensureLoaded()
    }

    /// Register a one-shot auto-retry: when the network returns, load the
    /// model again (unless it became ready some other way). Lets an
    /// offline-at-launch failure heal itself without user action.
    private func scheduleReloadOnReconnect() {
        NetworkMonitor.shared.runWhenOnline(id: "whisper.reload") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = self.state { return }
                self.log.info("Network back — retrying Whisper model load")
                await self.ensureLoaded()
            }
        }
    }

    /// Stop an in-progress model download. Cancels the load task — the
    /// HuggingFace download is URLSession-backed, so cooperative
    /// cancellation aborts the network transfer — and resets state so the
    /// UI unblocks immediately. No-op unless a download is actually
    /// running (so it can't interrupt CoreML init or a ready model).
    func cancelDownload() {
        guard case .downloading = state else { return }
        loadTask?.cancel()
        loadTask = nil
        state = .notLoaded
        downloadProgress = 0
        loadProgress = 0
        log.info("Whisper download cancelled by user")
    }

    var isReady: Bool {
        if case .ready = state { return kitBox != nil }
        return false
    }

    /// Conservative lower bound for the disk space we need before
    /// kicking off a fresh model download. The largest variant
    /// users typically pick (`large-v3-v20240930_626MB`) lands as
    /// ~1.5 GB of CoreML artefacts on disk after unpack; smaller
    /// variants are well under this. 2 GB free leaves headroom
    /// for HuggingFace's temp files, swap pressure, and a
    /// margin for a recording or two right after the download
    /// completes. Better to refuse early with a clear message
    /// than to wedge at "100% downloaded" because the temp file
    /// couldn't be moved into place.
    private static let minRequiredDiskBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Two-phase load: first explicit download (with progress) then
    /// CoreML init. Splitting lets the UI show a real progress bar
    /// during the 70 MB – 1.5 GB download.
    private func performLoad() async {
        let variant = modelID
        let repo = "argmaxinc/whisperkit-coreml"

        // Phase 0 — disk space preflight. Spinning on
        // `.downloading(progress: 1.0)` because the destination
        // volume is full is the worst possible failure mode: no
        // error, no recovery, the user thinks the model is
        // "loading forever". Refuse early with a concrete number
        // the user can act on.
        if let available = Self.availableDiskBytes(),
           available < Self.minRequiredDiskBytes {
            let neededGB = Double(Self.minRequiredDiskBytes) / 1_073_741_824.0
            let haveGB = Double(available) / 1_073_741_824.0
            let msg = String(
                format: String(localized: "Not enough disk space to download the transcription model — need %.1f GB free, only %.2f GB available. Free some space and try again."),
                neededGB, haveGB
            )
            log.error("Whisper download aborted — disk too full (\(available, privacy: .public) bytes free)")
            state = .failed(msg)
            return
        }

        // Phase 1 — resolve the model folder.
        //
        // A cached model resolves LOCALLY and never touches the network.
        // `WhisperKit.download` goes through the HuggingFace Hub API even
        // when every file is already on disk, so calling it "just to
        // resolve the folder" cost a round-trip on EVERY launch: measured
        // twice on 2026-07-28, 6.0s and 6.2s between app start and
        // "Loading models…", against a CoreML load of 1.1s. That's ~85% of
        // the startup wait spent asking huggingface.co about a model that
        // never moved — and a network call an app that promises "nothing
        // leaves your Mac" shouldn't be making at launch.
        //
        // Only a COMPLETE cache short-circuits. A folder that merely
        // exists isn't enough: `cancelDownload()` is a shipped button, so
        // an aborted transfer leaves a half-populated
        // `openai_whisper-<variant>` behind. Accepting that by name would
        // skip the download forever, `loadKit` would fail every launch,
        // and nothing recovers — `removeUnusedModels()` deliberately
        // spares the ACTIVE variant. `cachedModelFolder` requires the
        // compiled artefacts to actually be there, so a partial folder
        // falls through and gets re-fetched exactly as before.
        let folder: URL
        if let cached = Self.cachedModelFolder(variant: variant) {
            state = .loading(status: String(localized: "Loading transcription model…"))
            folder = cached
            log.info("Whisper model resolved from cache — no download check")
        } else {
            state = .downloading(progress: 0)
            downloadProgress = 0
            do {
                folder = try await Self.download(variant: variant, repo: repo) { fraction in
                    Task { @MainActor in
                        self.downloadProgress = fraction
                        self.state = .downloading(progress: fraction)
                    }
                }
            } catch {
                // User pressed Cancel (or the app is shutting the task
                // down): the HuggingFace download is URLSession-backed, so
                // cooperative cancellation aborts the transfer and surfaces
                // here. Reset to .notLoaded (a clean "not downloaded" state
                // the user can retry) rather than .failed (which reads like
                // an error they must fix).
                if error is CancellationError || Task.isCancelled {
                    log.info("Whisper download cancelled")
                    state = .notLoaded
                    downloadProgress = 0
                    return
                }
                // Offline (e.g. right after a restart before Wi-Fi is up):
                // don't dead-end at a scary error. Show a clear "we'll
                // finish when you reconnect" state and auto-retry.
                if NetworkMonitor.isOfflineError(error) {
                    log.error("Whisper download offline — will retry on reconnect")
                    state = .failed(String(localized: "You’re offline — Daisy will finish downloading the transcription model automatically when you reconnect."))
                    downloadProgress = 0
                    scheduleReloadOnReconnect()
                    return
                }
                log.error("Whisper download failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("Download failed: \(error.localizedDescription)")
                return
            }
        }

        // Phase 2 — load CoreML model
        state = .loading(status: String(localized: "Initializing CoreML model…"))
        // Wall-clock the load so cold (first ANE compile) vs warm
        // relaunch is visible in the log report. A cold compile of
        // large-v3 is tens of seconds; a warm relaunch (ANE cache hit)
        // should be single-digit. A warm relaunch that stays slow means
        // the OS aned cache is being evicted between runs — a different
        // problem than this prewarm-doubling fix.
        let loadStart = Date()
        loadStartedAt = loadStart
        startLoadProgressClock(startedAt: loadStart, variant: variant)
        do {
            let kit = try await Self.loadKit(folder: folder)
            self.kitBox = WhisperKitBox(kit)
            let loadSec = Date().timeIntervalSince(loadStart)
            finishLoadProgressClock(successfulDuration: loadSec, variant: variant)
            self.state = .ready
            loadStartedAt = nil
            log.info("WhisperKit ready — model \(variant, privacy: .public) — CoreML load \(String(format: "%.1f", loadSec), privacy: .public)s")
        } catch {
            finishLoadProgressClock(successfulDuration: nil, variant: variant)
            loadStartedAt = nil
            log.error("Whisper load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Init failed: \(error.localizedDescription)")
        }

        // Phase 3 — load Silero VAD in the background. Non-blocking:
        // Whisper is already .ready, transcribe() will run without
        // VAD until the first VAD load completes (and the first
        // transcribe after that picks it up). This avoids stalling
        // the "ready to record" UX on the Silero CoreML download.
        ensureVADLoadStarted()

        // Phase 4 — one-time warm-up decode (non-blocking). The first
        // real transcribe after a cold load pays CoreML/ANE function
        // specialization + tokenizer init on top of the actual decode;
        // for dictation that cost lands on the user's first hotkey
        // release. Pay it here instead, against 1 s of silence.
        warmUpIfNeeded()
    }

    /// Starts the UI-only estimate for CoreML loading. `WhisperKit` and
    /// `MLModel` do not expose progress for device specialization, so the
    /// percentage is explicitly approximate and capped below completion.
    private func startLoadProgressClock(startedAt: Date, variant: String) {
        loadProgressTask?.cancel()
        loadProgress = 0.02
        let stored = UserDefaults.standard.double(
            forKey: Self.loadDurationKeyPrefix + variant
        )
        let expectedSeconds = stored > 0 ? min(max(stored, 60), 600) : 360
        loadProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = max(0, Date().timeIntervalSince(startedAt))
                self.loadProgress = Self.estimatedLoadProgress(
                    elapsed: elapsed,
                    expectedDuration: expectedSeconds
                )
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func finishLoadProgressClock(
        successfulDuration: TimeInterval?,
        variant: String
    ) {
        loadProgressTask?.cancel()
        loadProgressTask = nil
        if let successfulDuration {
            loadProgress = 1
            // Leave headroom for normal run-to-run variance. A later cold
            // ANE compilation will teach the estimate its longer duration.
            let estimate = min(max(successfulDuration * 1.25, 60), 600)
            UserDefaults.standard.set(
                estimate,
                forKey: Self.loadDurationKeyPrefix + variant
            )
        } else {
            loadProgress = 0
        }
    }

    private func stopLoadProgressClock() {
        loadProgressTask?.cancel()
        loadProgressTask = nil
        loadStartedAt = nil
        loadProgress = 0
    }

    /// Logarithmic motion gives useful early feedback during both a warm
    /// two-second load and a several-minute cold ANE compilation. The cap
    /// prevents the estimate from claiming completion before Core ML does.
    nonisolated static func estimatedLoadProgress(
        elapsed: TimeInterval,
        expectedDuration: TimeInterval
    ) -> Double {
        let safeElapsed = max(0, elapsed)
        let safeExpected = max(1, expectedDuration)
        let fraction = Darwin.log(1 + safeElapsed) / Darwin.log(1 + safeExpected)
        return min(max(fraction, 0.02), 0.98)
    }

    /// Run a single throwaway `.lite` pass over 1 s of silence so the
    /// first user-visible transcribe doesn't pay cold-start costs.
    /// Fire-and-forget: the spawning Task returns immediately and the
    /// engine's in-actor semaphore (acquire/release inside
    /// `transcribe`) serializes the warm-up against any real pass that
    /// arrives first — a real caller queued behind it waits one short
    /// silence decode at most. Idempotent via `didWarmUp`.
    private func warmUpIfNeeded() {
        guard case .ready = state, !didWarmUp else { return }
        didWarmUp = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let t0 = Date()
            // 1 s of zeros at Whisper's 16 kHz input rate. NB: if the
            // Silero VAD finished loading first it will gate this
            // buffer to "no speech" and skip the Whisper decode — in
            // the common cold-start case VAD is still downloading/
            // loading (phase 3 above), so the pass takes the
            // full-buffer path and warms the decoder for real.
            let silence = [Float](repeating: 0, count: 16_000)
            do {
                _ = try await self.transcribe(samples: silence, language: nil, profile: .lite)
                self.log.info("Whisper warm-up pass done in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            } catch {
                // Non-fatal by design — warm-up is purely an optimization.
                self.log.info("Whisper warm-up pass failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if canImport(FluidAudio)
    /// Kick off Silero VAD model load if it isn't already loading /
    /// loaded. Idempotent. Runs detached so it doesn't extend the
    /// visible "loading Whisper" phase the user already waits through.
    private func ensureVADLoadStarted() {
        if vadBox != nil || vadLoadTask != nil { return }
        vadLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Default threshold 0.85 is the FluidAudio recommended
                // value; lower (e.g. 0.5) would let more borderline
                // chunks through and partially undo what we're trying
                // to gain here. We can revisit if we see real speech
                // being clipped.
                let cfg = VadConfig(defaultThreshold: 0.85)
                // Offline-first: cached Silero loads with FluidAudio's
                // network hard-blocked; first run opens an explicit
                // download window via the guard.
                let vad: VadManager
                do {
                    vad = try await VadManager(config: cfg)
                } catch let error where FluidAudioNetworkGuard.isOfflineRejection(error) {
                    vad = try await FluidAudioNetworkGuard.withDownloadsAllowed("Silero VAD") {
                        try await VadManager(config: cfg)
                    }
                }
                self.vadBox = VadManagerBox(vad)
                self.log.info("Silero VAD loaded")
            } catch {
                self.log.error("Silero VAD load failed (continuing without VAD): \(error.localizedDescription, privacy: .public)")
            }
            self.vadLoadTask = nil
        }
    }
    #else
    private func ensureVADLoadStarted() {}
    #endif

    /// Available bytes on the volume that backs the user's home
    /// directory — same volume HuggingFace stages downloads into
    /// (~/Library/Caches). `volumeAvailableCapacityForImportantUsage`
    /// is Apple's recommended key for "can I write a big file
    /// here?"; it respects purgeable-space accounting (TimeMachine
    /// snapshots, iCloud caches) better than the raw free-bytes
    /// number. Returns nil if the lookup fails — caller treats
    /// that as "no preflight" rather than aborting.
    nonisolated private static func availableDiskBytes() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Off-main download — returns the folder containing the unpacked
    /// CoreML files. Progress is reported via the callback on the main
    /// actor (we hop back).
    nonisolated private static func download(
        variant: String,
        repo: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Explicit downloadBase keeps models OUT of ~/Documents —
        // WhisperKit's default lands there, which iCloud "Desktop &
        // Documents" sync then uploads and evicts (see modelsDownloadBase).
        try await WhisperKit.download(
            variant: variant,
            downloadBase: modelsDownloadBase(),
            from: repo,
            progressCallback: { p in
                progress(p.fractionCompleted)
            }
        )
    }

    // MARK: - Cache inspection

    /// One entry per downloaded Whisper model variant — folder URL,
    /// the short variant id (e.g. `large-v3-v20240930_626MB`), and
    /// the recursive byte size on disk. Used by the Transcription
    /// settings tab to show "Models cached: X.X GB" and to offer a
    /// one-click cleanup of variants the user isn't using.
    struct CachedModel: Hashable, Sendable {
        let variant: String
        let url: URL
        let sizeBytes: Int64
    }

    /// Enumerate downloaded model folders under `whisperCacheRoot()` —
    /// normally `~/Library/Application Support/Daisy/huggingface/models/
    /// argmaxinc/whisperkit-coreml/`, or the legacy `~/Documents/…` root
    /// until its one-shot migration has run.
    /// Returns an empty array if the folder doesn't exist yet
    /// (no models ever downloaded).
    /// Folder for `variant` when it's on disk AND complete — nil
    /// otherwise, which sends the caller to the downloader.
    ///
    /// Deliberately cheap: one directory read, no recursive sizing. It
    /// sits on the launch path, and `cachedModels()` walks and `stat`s
    /// every file of every cached model (up to ~1.5 GB of artefacts) to
    /// build its size report — fine for the Settings screen it was
    /// written for, wasteful before we've even started loading.
    ///
    /// "Complete" = the compiled CoreML bundles are present. WhisperKit
    /// needs the mel/encoder/decoder trio, so fewer than three
    /// `.mlmodelc` entries means an interrupted download, not a model.
    nonisolated static func cachedModelFolder(variant: String) -> URL? {
        guard let root = whisperCacheRoot() else { return nil }
        let folder = root.appendingPathComponent("openai_whisper-\(variant)")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return nil }
        let compiled = contents.filter { $0.hasSuffix(".mlmodelc") }
        return compiled.count >= 3 ? folder : nil
    }

    nonisolated static func cachedModels() -> [CachedModel] {
        guard let root = whisperCacheRoot() else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        // WhisperKit prepends "openai_whisper-" to every variant
        // folder. HuggingFace's downloader also stashes sibling
        // bookkeeping directories at the same level — `.locks`,
        // `.cache`, occasional tokenizer bundles — which previously
        // got counted as "models on disk" (user saw `2 models` after
        // downloading one). Require the prefix so only real model
        // folders make it into the cache report.
        let prefix = "openai_whisper-"
        return entries.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            let folderName = url.lastPathComponent
            guard folderName.hasPrefix(prefix) else { return nil }
            let variant = String(folderName.dropFirst(prefix.count))
            return CachedModel(
                variant: variant,
                url: url,
                sizeBytes: directorySize(at: url)
            )
        }
    }

    /// Total bytes consumed by every downloaded Whisper variant on
    /// disk. Sum of `cachedModels().sizeBytes`. Convenience wrapper
    /// so the UI doesn't have to fold the list itself.
    nonisolated static func totalCacheSizeBytes() -> Int64 {
        cachedModels().reduce(0) { $0 + $1.sizeBytes }
    }

    /// Remove every downloaded model variant except the one the user
    /// currently has active. Idempotent — safe to call when there's
    /// only one cached variant (it'll just no-op). Returns the freed
    /// bytes for caller-side reporting.
    @MainActor
    func removeUnusedModels() async -> Int64 {
        let active = modelID
        let cached = Self.cachedModels()
        let fm = FileManager.default
        var freed: Int64 = 0
        for model in cached where model.variant != active {
            do {
                try fm.removeItem(at: model.url)
                freed += model.sizeBytes
                log.info("Removed cached Whisper model \(model.variant, privacy: .public) (\(model.sizeBytes) bytes)")
            } catch {
                log.error("Failed to remove \(model.variant, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Stuck legacy cache: migration skips when ~/Documents files are
        // iCloud-evicted, and once a fresh download populates the new
        // root the legacy copy becomes invisible dead weight in the
        // user's iCloud quota. Deleting evicted files needs NO
        // materialization, so this is cheap. Never touches the legacy
        // root while it's still the active fallback.
        if let old = Self.legacyCacheRoot(),
           let current = Self.whisperCacheRoot(),
           current.standardizedFileURL.path != old.standardizedFileURL.path,
           fm.fileExists(atPath: old.path) {
            do {
                try fm.removeItem(at: old)
                log.info("Removed stale legacy Whisper model cache in ~/Documents")
            } catch {
                log.warning("Couldn't remove legacy Whisper cache: \(error.localizedDescription, privacy: .public)")
            }
        }
        return freed
    }

    /// Base directory handed to `WhisperKit.download(downloadBase:)`.
    /// Lives under ~/Library/Application Support — NOT ~/Documents.
    ///
    /// WhisperKit's default base is `~/Documents/huggingface`, and Daisy
    /// is NOT sandboxed (the old comment here assumed a container
    /// Documents — wrong), so until 2026-08 every model landed in the
    /// user's real Documents folder. With iCloud "Desktop & Documents"
    /// sync that meant: ~0.6–1.5 GB of model artefacts uploaded into the
    /// user's iCloud quota, and — worse — EVICTED first when the disk
    /// filled up. The next launch then re-materialized every weight file
    /// over the network ("model takes forever to load", field report
    /// 2026-08-19). ~/Library is never synced or evicted by iCloud.
    nonisolated private static func modelsDownloadBase() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport
            .appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    /// The legacy (≤1.0.7.60) model location inside ~/Documents.
    nonisolated private static func legacyCacheRoot() -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// One-shot migration of the legacy ~/Documents model cache into
    /// Application Support. `static let` gives thread-safe run-once.
    ///
    /// A plain same-volume `moveItem` is instant for local files. If any
    /// model file was already evicted to iCloud the move can fail (moving
    /// out of an iCloud domain forces materialization) — in that case we
    /// leave the legacy cache in place and keep reading from it
    /// (`whisperCacheRoot` falls back), so nothing breaks; fresh
    /// downloads still go to the new home.
    nonisolated private static let legacyCacheMigration: Void = {
        let log = Logger(subsystem: "app.essazanov.Daisy", category: "Whisper")
        let fm = FileManager.default
        guard let old = legacyCacheRoot(),
              let base = modelsDownloadBase() else { return }
        let new = whisperKitModelsRoot(under: base)
        guard fm.fileExists(atPath: old.path),
              !fm.fileExists(atPath: new.path) else { return }
        // If ANY legacy file is already iCloud-evicted, moving the tree
        // out of the iCloud domain would force a synchronous
        // materialization of hundreds of MB — potentially ON THE MAIN
        // THREAD (first whisperCacheRoot call comes from performLoad).
        // Skip the move entirely in that case; whisperCacheRoot keeps
        // serving the legacy root and fresh downloads use the new home.
        if let enumerator = fm.enumerator(at: old, includingPropertiesForKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]) {
            for case let url as URL in enumerator where SessionStore.isCloudEvicted(url) {
                log.warning("Whisper model cache migration skipped — legacy cache has iCloud-evicted files; still reading from ~/Documents")
                return
            }
        }
        do {
            try fm.createDirectory(
                at: new.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: old, to: new)
            log.info("Migrated Whisper model cache out of ~/Documents into Application Support")
            // Sweep the now-empty ~/Documents/huggingface skeleton so it
            // stops syncing to iCloud. Only removes directories that are
            // actually empty — anything else (HubApi locks with content,
            // other tools' caches) survives.
            var parent = old.deletingLastPathComponent()
            for _ in 0..<3 {
                let contents = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
                let removable = contents.isEmpty
                    || contents.allSatisfy { $0 == ".DS_Store" }
                guard removable, parent.lastPathComponent != "Documents" else { break }
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        } catch {
            log.warning("Whisper model cache migration failed — continuing to read the legacy ~/Documents cache: \(error.localizedDescription, privacy: .public)")
        }
    }()

    /// Mirrors WhisperKit's own internal path resolution — kept
    /// in one place so a future Argmax-side change to the layout is
    /// a one-spot fix here.
    nonisolated private static func whisperKitModelsRoot(under base: URL) -> URL {
        base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    nonisolated private static func whisperCacheRoot() -> URL? {
        _ = legacyCacheMigration
        guard let base = modelsDownloadBase() else { return legacyCacheRoot() }
        let new = whisperKitModelsRoot(under: base)
        if FileManager.default.fileExists(atPath: new.path) { return new }
        // Migration didn't (couldn't) run — keep serving the legacy cache
        // until a fresh download populates the new root.
        if let old = legacyCacheRoot(), FileManager.default.fileExists(atPath: old.path) {
            return old
        }
        return new
    }

    /// Recursive directory size in bytes. Walks the enumerator
    /// once; cheaper than `du`-shelling out for sub-1GB trees.
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Off-main CoreML init — heavy CPU/Neural Engine work. Stays off
    /// MainActor so it doesn't freeze the UI.
    nonisolated private static func loadKit(folder: URL) async throws -> WhisperKit {
        // `prewarm: false` (was `true`). In WhisperKit, `prewarm` runs a
        // SEPARATE `loadModels(prewarmMode: true)` pass BEFORE the real
        // `loadModels()` — the 626 MB model is instantiated TWICE per
        // launch. The ANE weight compilation that dominates a cold load
        // happens inside `loadModels()` regardless of the flag
        // (prewarmMode only changes timing bookkeeping + an early
        // return), and `load: true` alone returns a fully specialized,
        // transcribe-ready model. The old config therefore paid a whole
        // extra model instantiation on EVERY launch for no benefit — in
        // the 1.0.7.33 field log the "Prewarming models..." pass ate
        // ~132 s of the 136 s startup wait, while the load that followed
        // took 4 s (its ANE cache was warmed by that prewarm pass). We
        // still warm the decoder off the critical path via
        // `warmUpIfNeeded()` (Phase 4 in `performLoad`), so first-decode
        // latency is unchanged.
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    // MARK: - In-actor semaphore

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
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    // MARK: - Transcribe

    /// Decode cost profile for a transcription pass. `.lite` trims the
    /// expensive knobs (4 ANE workers, greedy `topK: 1`, no temperature
    /// fallbacks) for throwaway live passes; `.full` is the quality path
    /// used for the meeting/voice-note final pass and for the Full live
    /// tier. `.dictationFinal` sits in between: same trimmed search
    /// width as `.lite`, but ONE temperature-fallback retry — the
    /// dictation final pass pastes its output verbatim with no later
    /// cleanup pass, so a garbled first decode deserves a second
    /// chance, while a `.full`-width search on a few seconds of speech
    /// is pure release→paste latency. The anti-hallucination thresholds
    /// + VAD are identical across all profiles — only the search width /
    /// retry / worker counts change.
    enum DecodeProfile: Sendable, Equatable {
        case full
        case lite
        case dictationFinal

        /// Temperature-fallback retries when the anti-hallucination
        /// filters trip. `.full` keeps the historical 3 (see the
        /// trade-off note in `transcribe`).
        var temperatureFallbackCount: Int {
            switch self {
            case .full:           return 3
            case .dictationFinal: return 1
            case .lite:           return 0
            }
        }
        /// Token search width — greedy everywhere off the quality path.
        var topK: Int { self == .full ? 5 : 1 }
        /// ANE worker count — 16 only for the full-quality pass; 16 on
        /// a short span just burst-overheats the ANE (see `.lite` note).
        var concurrentWorkerCount: Int { self == .full ? 16 : 4 }

        /// avgLogprob floor for the blanket confidence cut (post-filter
        /// rule 2). Dictation is deliberate push-to-talk speech pasted
        /// VERBATIM: dropping a real-but-low-confidence segment yields an
        /// EMPTY paste (total failure), far worse than a meeting shedding
        /// one noisy line. So `.dictationFinal` relaxes the floor and leans
        /// on the Silero VAD pre-pass as the noise gate; meeting/live keep
        /// the strict −0.8. (Root cause of the 1.0.7.35 "Standard dictation
        /// pastes nothing" report: the strict cut silently dropped the
        /// user's only segment.)
        var logProbFloor: Double { self == .dictationFinal ? -2.2 : -0.8 }
        /// avgLogprob floor for the short (≤2-word) utterance cut
        /// (post-filter rule 3). Effectively off for dictation — same
        /// reasoning as `logProbFloor`.
        var shortUtteranceLogProbFloor: Double { self == .dictationFinal ? -2.2 : -0.6 }
    }

    /// Run a transcription pass against 16 kHz mono Float samples.
    /// Multiple callers are serialized. `language` is a two-letter ISO
    /// code ("en", "ru") or nil for auto-detect. `profile` trades decode
    /// cost for quality — see `DecodeProfile`.
    /// `biasTerms` — canonical spellings to nudge the decoder toward
    /// (the dictation vocabulary). Default `[]` → no biasing, so meeting
    /// and voice-note passes are byte-identical to before. Only the
    /// dictation final pass populates it (see `Transcriber.runFinalPass`).
    func transcribe(samples: [Float], language: String?, profile: DecodeProfile = .full, biasTerms: [String] = []) async throws -> [WhisperSegment] {
        await acquireSlot()
        defer { releaseSlot() }

        // Cooperative cancellation — bail before any heavy work if the
        // calling task was cancelled while queued behind another pass
        // (dictation stop cancels the in-flight live window; a rotated
        // session cancels its finalize task). The `defer` above
        // releases the slot to the next waiter.
        try Task.checkCancellation()

        await ensureLoaded()
        guard let box = kitBox else { throw WhisperEngineError.notReady }

        return try await transcribeLocked(
            samples: samples,
            language: language,
            profile: profile,
            biasTerms: biasTerms,
            box: box
        )
    }

    /// Batch transcription with a model chosen for this job only. This
    /// does not mutate `modelID`, does not write UserDefaults, and does not
    /// reload the meeting engine. Calls remain serialized with live and
    /// final-pass transcription through the same in-actor slot.
    func transcribe(
        samples: [Float],
        language: String?,
        modelID requestedModelID: String,
        profile: DecodeProfile = .full,
        biasTerms: [String] = []
    ) async throws -> [WhisperSegment] {
        await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()

        let box: WhisperKitBox
        if requestedModelID == modelID {
            await ensureLoaded()
            guard let current = kitBox else { throw WhisperEngineError.notReady }
            box = current
        } else {
            box = try await alternateModelBox(for: requestedModelID)
        }

        return try await transcribeLocked(
            samples: samples,
            language: language,
            profile: profile,
            biasTerms: biasTerms,
            box: box
        )
    }

    /// Drop the loaded Whisper graphs under memory pressure. (The small
    /// Silero VAD box stays — it's a rounding error next to these.)
    ///
    /// The models are 626 MB (default) to 1.5 GB each, they load at app
    /// start and — before this — nothing ever unloaded them, so a Mac
    /// that never records still carried the weight all day, and a
    /// re-transcribe with a second variant could hold both at once. On
    /// an 8 GB machine that is the difference between "Daisy is open"
    /// and the system swapping (audit 2026-09-01).
    ///
    /// Refuses while a recording or a transcription is in flight —
    /// pulling the graph out from under a decode would fail the pass,
    /// which is a far worse trade than the memory. The next
    /// `ensureLoaded()` reloads from the on-disk cache.
    func releaseModelsUnderMemoryPressure() {
        // `isBusy` is the authoritative check: it's true for the whole
        // duration of any decode, whoever started it. Session state
        // alone missed three real callers — interrupted-recording
        // recovery, quit-finalize and the Voice Memos ingestor — all of
        // which run at launch with the session idle, and all of which
        // would have failed with `.notReady` if pressure arrived while
        // they waited on `ensureLoaded()` (review find, 2026-09-02).
        guard !isBusy else {
            log.info("Memory pressure: keeping Whisper loaded — a decode is running")
            return
        }
        guard !RecordingSession.isCapturingOrTranscribing else {
            log.info("Memory pressure: keeping Whisper loaded — a session is in flight")
            return
        }
        guard kitBox != nil || alternateKitBox != nil else { return }
        kitBox = nil
        alternateKitBox = nil
        alternateModelID = nil
        state = .notLoaded
        log.info("Memory pressure: released Whisper model(s)")
    }

    /// Drop a large alternate CoreML graph as soon as the batch job ends.
    /// The normal meeting model remains loaded throughout.
    func releaseAlternateModel(_ requestedModelID: String) {
        guard alternateModelID == requestedModelID else { return }
        alternateKitBox = nil
        alternateModelID = nil
    }

    private func alternateModelBox(for requestedModelID: String) async throws -> WhisperKitBox {
        guard Self.availableModels.contains(where: { $0.id == requestedModelID }) else {
            throw WhisperEngineError.unsupportedModel(requestedModelID)
        }
        if alternateModelID == requestedModelID, let alternateKitBox {
            return alternateKitBox
        }

        alternateKitBox = nil
        alternateModelID = nil
        if let available = Self.availableDiskBytes(),
           Self.cachedModelFolder(variant: requestedModelID) == nil,
           available < Self.minRequiredDiskBytes {
            throw WhisperEngineError.notEnoughDiskSpace
        }

        let folder: URL
        if let cached = Self.cachedModelFolder(variant: requestedModelID) {
            folder = cached
        } else {
            folder = try await Self.download(
                variant: requestedModelID,
                repo: "argmaxinc/whisperkit-coreml",
                progress: { _ in }
            )
        }
        try Task.checkCancellation()
        let box = WhisperKitBox(try await Self.loadKit(folder: folder))
        alternateModelID = requestedModelID
        alternateKitBox = box
        return box
    }

    /// Core decode pipeline. The caller owns the engine slot and supplies
    /// the exact model box, which lets normal and job-scoped entry points
    /// share every VAD, vocabulary and hallucination safeguard.
    private func transcribeLocked(
        samples: [Float],
        language: String?,
        profile: DecodeProfile,
        biasTerms: [String],
        box: WhisperKitBox
    ) async throws -> [WhisperSegment] {

        // Vocabulary biasing (dictation only — every other caller passes
        // `biasTerms: []`, so this stays a no-op for meetings/voice notes).
        // Tokenise the user's canonical spellings into decoder prompt
        // tokens (Whisper's `initial_prompt` analog — prepended to the
        // prefill tokens) so the decode is nudged toward producing them;
        // strip the tokenizer's special tokens so only word-piece IDs go
        // in. Best-effort: if the tokenizer isn't ready we just skip
        // biasing rather than failing the pass.
        var biasPromptTokens: [Int]? = nil
        // Word-tokens of each term that ACTUALLY reached the decoder —
        // the echo filter's reference. Built term-by-term alongside the
        // prompt so the two can never disagree about what was sent.
        var biasSentTerms: [[String]] = []
        if !biasTerms.isEmpty, let tokenizer = box.kit.tokenizer {
            // Cap the prompt. Whisper's decoder prompt window is ~224
            // tokens; a user who bulk-imported several hundred
            // vocabulary rules would otherwise overflow it, and what
            // overflows isn't dropped politely — it displaces the audio
            // context the decoder actually needs.
            //
            // Accumulate whole terms until the token budget is spent,
            // rather than encoding everything and truncating the token
            // array. Truncating mid-term would leave a half-word in the
            // prompt, and — the reason it matters here — would make the
            // echo filter's term list a superset of what was really
            // sent, so terms the decoder never saw could still delete
            // speech from the transcript.
            var tokens: [Int] = []
            for term in biasTerms.prefix(Self.maxBiasTerms) {
                let encoded = tokenizer.encode(text: " " + term)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                guard !encoded.isEmpty else { continue }
                if tokens.count + encoded.count > Self.maxBiasPromptTokens { break }
                tokens += encoded
                let words = Self.biasWordTokens(term)
                if !words.isEmpty { biasSentTerms.append(words) }
            }
            if !tokens.isEmpty { biasPromptTokens = tokens }
            if biasSentTerms.count < biasTerms.count {
                log.info("Vocabulary bias sent \(biasSentTerms.count, privacy: .public) of \(biasTerms.count, privacy: .public) terms (prompt budget)")
            }
        }

        // Per-pass timing instrumentation (privacy-safe: durations and
        // counts only, never transcript content). Attributes dictation
        // release→paste latency between the Silero VAD pre-pass and
        // the Whisper decode itself.
        let passStart = Date()

        // Anti-hallucination knobs. Whisper has a well-documented
        // failure mode where silence or non-speech ambient sound
        // (fans, packing tape, HVAC) gets decoded as text from its
        // YouTube training data — "Thanks for watching!", "ご視聴
        // ありがとうございました", "Спасибо за внимание", or
        // short single tokens like "so", "you", "はい".
        //
        // Thresholds tuned 2026-05-18 after QA feedback that
        // ambient noise was still producing "so" / "はい" leaks
        // through the 0.55 / -1.0 baseline. Tier-1 values
        // cross-validated from whisper.cpp, faster-whisper and
        // WhisperKit community issues — see CHANGELOG for citations.
        //
        //   noSpeechThreshold       — segment dropped if Whisper's
        //                             own "is this non-speech?" prob
        //                             exceeds this. Lower = stricter.
        //                             Default 0.6 → 0.55 → 0.4 here.
        //                             0.4 catches single-token leaks.
        //   compressionRatioThreshold — high compression = repetitive
        //                             text ("chocolate chocolate
        //                             chocolate"); above threshold,
        //                             segment is discarded. 2.4 is the
        //                             upstream recommendation.
        //   logProbThreshold        — drop low-confidence segments
        //                             (average log-prob below this).
        //                             -1.0 is the upstream recommendation.
        //   temperatureFallbackCount — re-sample with higher temperature
        //                             up to N times when the above
        //                             filters trigger. Kept at 3 — see
        //                             the trade-off note in faster-whisper
        //                             #621 (fallbacks can _increase_
        //                             hallucinations on pure noise);
        //                             revisit if the post-filter below
        //                             stops being enough.
        //
        // Note on language locking: if the caller pinned a language
        // (`language != nil`) we never auto-detect, which alone kills
        // a class of hallucinations where Whisper drifts into the
        // wrong language on noise (English speaker → spurious
        // "ありがとうございました"). `Transcriber` snaps `language`
        // to the locked locale after the first few confident segments.
        // Lite live passes trade search width for speed/energy: 4 ANE
        // workers instead of the macOS default 16 (16 on a short VAD span
        // every few seconds just burst-overheats the ANE), greedy
        // `topK: 1`, and no temperature fallbacks. The anti-hallucination
        // thresholds + VAD are kept identical — the meeting final pass
        // on Stop (`.full`) cleans up anything Lite missed; dictation's
        // inline final pass uses `.dictationFinal` (lite width, one
        // fallback retry) since its output is pasted verbatim. All knob
        // values live on `DecodeProfile`.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: profile.temperatureFallbackCount,
            topK: profile.topK,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            promptTokens: biasPromptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.4,
            concurrentWorkerCount: profile.concurrentWorkerCount,
            chunkingStrategy: .vad
        )

        // ── VAD pre-pass ───────────────────────────────────────────
        // Carve `samples` into speech-only spans before handing it
        // to Whisper. This is the single biggest anti-hallucination
        // lever (see the multi-source justification at the top of
        // this method). If VAD isn't loaded yet (still downloading
        // its CoreML model, or first transcribe of the session) we
        // fall through to the legacy full-buffer Whisper path.
        let vadStart = Date()
        let speechSpans: [SpeechSpan] = await runVADPrepass(samples: samples)
        let vadMs = Int(Date().timeIntervalSince(vadStart) * 1000)

        // Run Whisper per speech span (or once on the whole buffer
        // if VAD wasn't available). Per-span timings are translated
        // back into the original-buffer coordinate space so the
        // Transcriber doesn't notice the VAD slicing.
        if speechSpans.isEmpty {
            // VAD says "no speech" — skip Whisper entirely. This is
            // the desired behaviour for ambient-noise-only buffers:
            // empty result, no hallucinated text, no compute spent.
            log.info("Whisper pass: vad=\(vadMs, privacy: .public)ms decode=0ms (no speech) audio=\(samples.count, privacy: .public) samples")
            return []
        }

        // Decode + post-filter as ONE reusable pass so the dictation
        // rescue below can re-run it with adjusted options.
        // `echoTerms` is a PARAMETER, not a capture: the rescue pass
        // below sends no prompt, so it must not run the prompt-echo
        // filter. Closing over the term list instead would have the
        // rescue re-delete the very text it exists to recover.
        func runDecodePass(
            _ options: DecodingOptions,
            echoTerms: [[String]]
        ) async throws -> (kept: [WhisperSegment], rawCount: Int) {
        var allRaw: [(spanOffsetSec: Double, segs: [TranscriptionSegment])] = []
        let decodeStart = Date()
        for span in speechSpans {
            // Cooperative cancellation point between spans — a
            // cancelled live pass exits here instead of decoding the
            // remaining spans; `defer` releases the engine slot.
            try Task.checkCancellation()
            let chunk: [Float]
            let offsetSec: Double
            if span.isFullBuffer {
                chunk = samples
                offsetSec = 0
            } else {
                let lo = max(0, min(samples.count, span.startSample))
                let hi = max(lo, min(samples.count, span.endSample))
                guard hi > lo else { continue }
                chunk = Array(samples[lo..<hi])
                offsetSec = Double(lo) / Self.audioSampleRate
            }
            // Skip pathologically short chunks — Whisper produces
            // garbage on sub-200ms inputs even with our thresholds.
            if Double(chunk.count) / Self.audioSampleRate < 0.20 { continue }
            let results = try await box.kit.transcribe(audioArray: chunk, decodeOptions: options)
            for result in results {
                allRaw.append((offsetSec, result.segments))
            }
        }
        let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)
        let rawSegmentCount = allRaw.reduce(0) { $0 + $1.segs.count }
        log.info("Whisper pass: vad=\(vadMs, privacy: .public)ms decode=\(decodeMs, privacy: .public)ms total=\(Int(Date().timeIntervalSince(passStart) * 1000), privacy: .public)ms spans=\(speechSpans.count, privacy: .public) rawSegments=\(rawSegmentCount, privacy: .public) audio=\(samples.count, privacy: .public) samples")

        // Post-filter pipeline. Each rule kills a distinct class of
        // hallucination observed in QA; the comments name the class.
        // Post-filter pipeline (explicit loop so we can report WHY
        // segments were dropped — a silent 0-segment dictation was
        // impossible to diagnose from the pass log alone). Privacy-safe:
        // counts + one logprob number, never transcript text.
        var previousText: String?
        var kept: [WhisperSegment] = []
        var dEmpty = 0, dHalluc = 0, dLogprob = 0, dShort = 0, dDup = 0, dBiasEcho = 0
        var worstLogprob = 0.0
        for (offsetSec, segs) in allRaw {
            for seg in segs {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { dEmpty += 1; continue }

                // (1) Known YouTube-training artefacts (full phrases).
                if Self.isKnownHallucination(text) { dHalluc += 1; continue }

                // (1b) Prompt echo. Whisper's documented failure mode
                // with `initial_prompt`: on a low-information span it
                // reads the prompt back out as if it were speech, so the
                // user's own vocabulary list appears in the transcript
                // as something someone said. Harmless-looking in
                // dictation (one bad paste) and much worse in a meeting,
                // where it lands mid-conversation attributed to a
                // speaker. Drop any segment whose text is contained in
                // the bias prompt.
                if Self.looksLikeBiasEcho(text, terms: echoTerms) {
                    dBiasEcho += 1
                    continue
                }

                worstLogprob = min(worstLogprob, Double(seg.avgLogprob))

                // (2) Confidence filter. Threshold is profile-driven:
                // meetings/live keep the strict −0.8 that kills ambient
                // "so"/"はい"/"you" leaks; dictation relaxes it (see
                // `DecodeProfile.logProbFloor`) so a real-but-quiet
                // utterance is never silently dropped to an empty paste.
                if Double(seg.avgLogprob) < profile.logProbFloor { dLogprob += 1; continue }

                // (3) Short-utterance + middling-confidence cut, also
                // profile-driven (off for dictation).
                let wordCount = text
                    .split(whereSeparator: { $0.isWhitespace })
                    .count
                if wordCount <= 2 && Double(seg.avgLogprob) < profile.shortUtteranceLogProbFloor { dShort += 1; continue }

                // (4) Adjacent-duplicate collapse. Only fires when
                // the text is long enough that a real repeat is
                // implausible (avoids killing "yes, yes" / "ok ok").
                if text.count >= 6, text == previousText { dDup += 1; continue }
                previousText = text

                // Translate per-span timings back into the original
                // buffer's coordinate space (`offsetSec` is 0 when
                // VAD wasn't used or returned a full-buffer span).
                kept.append(WhisperSegment(
                    start: offsetSec + Double(seg.start),
                    end: offsetSec + Double(seg.end),
                    text: text
                ))
            }
        }
        if (dEmpty + dHalluc + dLogprob + dShort + dDup + dBiasEcho) > 0 {
            log.info("Whisper post-filter [\(String(describing: profile), privacy: .public)]: kept \(kept.count, privacy: .public)/\(rawSegmentCount, privacy: .public) — dropped empty=\(dEmpty, privacy: .public) halluc=\(dHalluc, privacy: .public) logprob=\(dLogprob, privacy: .public) short=\(dShort, privacy: .public) dup=\(dDup, privacy: .public) biasEcho=\(dBiasEcho, privacy: .public), worstLogprob=\(String(format: "%.2f", worstLogprob), privacy: .public)")
        }
        return (kept, rawSegmentCount)
        }  // runDecodePass

        let first = try await runDecodePass(options, echoTerms: biasSentTerms)

        // Dictation rescue pass (field bug 2026-07-25, Egor's log
        // report): with vocabulary-bias promptTokens active, WhisperKit
        // can return a single segment with EMPTY text on short clips —
        // the decode "succeeds" ("rawSegments=1"), the post-filter
        // drops it ("kept 0/1 — dropped empty=1"), and dictation
        // pastes nothing. Parakeet has no prompt support, which is why
        // only the Fast engine appeared to work; the Apple engine's
        // silent Whisper fallback funnelled into this same path. When
        // the paste-verbatim dictation pass ends up empty despite VAD
        // hearing real speech, retry ONCE without the bias prompt and
        // with the upstream-default no-speech threshold. Meetings and
        // voice notes (.full/.lite) keep single-pass behaviour.
        //
        // Generalized for meetings (D-4): the same trap is now reachable
        // there, because the meeting final pass carries the bias too.
        // It can't fire on the live `.lite` passes — those never carry
        // bias — so the every-few-seconds path keeps its single-decode
        // cost.
        //
        // `rawCount > 0` is what bounds the cost, and it is the bug's
        // actual signature: the decoder DID emit segments and the
        // post-filter dropped every one. A pass that decoded nothing at
        // all heard nothing, and re-decoding it would just spend the
        // time again. That matters most for a meeting, where this pass
        // covers the whole archive: the 20-minute session this file
        // cites at ~237 s would otherwise pay ~474 s while HOLDING the
        // engine slot, blocking the other stream's final pass behind it.
        //
        // (VAD-empty buffers already returned before any decode — but
        // only when Silero is loaded. `runVADPrepass` falls back to a
        // whole-buffer span while the model is still downloading, and
        // `rawCount > 0` is what covers that case.)
        //
        // UPSTREAM FIX (argmax-oss-swift v1.1.0, PR #514, 2026-07-30):
        // the root cause — an EOT sampled during forced prompt prefill
        // ended the segment before any content token — is fixed in the
        // decode loop itself, so bias-passes should no longer come back
        // falsely empty. The same PR re-anchors the
        // `firstTokenLogProbThreshold` check off the prefill throwaway
        // token, killing the spurious temperature fallbacks every
        // bias-pass silently paid. KEEP this rescue anyway: it still
        // covers the VAD-fallback window above (Silero not yet loaded →
        // whole-buffer span) and any future upstream regression. With
        // the fix it should almost never fire, so its cost rounds to
        // zero — it was always gated on `kept.isEmpty && rawCount > 0`,
        // never a per-pass double decode.
        let biasWasActive = biasPromptTokens != nil
        if first.kept.isEmpty, first.rawCount > 0,
           profile == .dictationFinal || biasWasActive {
            log.warning("Pass empty [\(String(describing: profile), privacy: .public)] (raw=\(first.rawCount, privacy: .public), bias=\(biasWasActive, privacy: .public)) — rescue pass without bias prompt")
            let rescueOptions = DecodingOptions(
                task: .transcribe,
                language: language,
                temperatureFallbackCount: profile.temperatureFallbackCount,
                topK: profile.topK,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false,
                promptTokens: nil,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                // Relax the no-speech gate for DICTATION only. There an
                // empty result is total failure — nothing gets pasted —
                // so it's worth risking a noisy line. A meeting can
                // afford to shed one, and `.full` keeps the strict gate
                // precisely because the input that triggers a rescue is
                // near-silence, which is where the loose setting
                // hallucinates.
                noSpeechThreshold: profile == .dictationFinal ? 0.6 : 0.4,
                concurrentWorkerCount: profile.concurrentWorkerCount,
                chunkingStrategy: .vad
            )
            // No prompt was sent, so nothing can be a prompt echo.
            let rescue = try await runDecodePass(rescueOptions, echoTerms: [])
            return rescue.kept
        }
        return first.kept
    }

    // MARK: - Vocabulary bias

    /// Ceiling on how many vocabulary terms reach the decoder prompt.
    /// The audit's number. Terms arrive in the user's rule-list order,
    /// so for a hand-curated list the cap keeps the ones they added
    /// first; for a bulk import that order is the file's, so it keeps an
    /// arbitrary 50 rather than a chosen 50.
    nonisolated static let maxBiasTerms = 50

    /// Hard ceiling in tokens. Whisper's decoder prompt window is ~224
    /// tokens and everything past it displaces real audio context, so
    /// this leaves clear headroom rather than filling it.
    nonisolated static let maxBiasPromptTokens = 160

    /// How many WHOLE vocabulary terms a segment must reproduce,
    /// back-to-back and in list order, before we call it a prompt echo
    /// rather than speech.
    ///
    /// This is the number that decides whether the filter is safe. The
    /// obvious test — "the segment appears inside the prompt text" —
    /// deletes real speech, because a single vocabulary entry trivially
    /// appears inside the prompt: a user with a colleague's name in
    /// their vocabulary would lose the line "Мария Иванова." from a
    /// meeting transcript, silently and permanently. Two terms isn't
    /// enough either — "Claude Code, Kubernetes" is an ordinary
    /// standup sentence. Three consecutive terms, in the same order the
    /// user's list has them, with nothing else in the segment, is the
    /// decoder reading its prompt back.
    ///
    /// A vocabulary shorter than this simply can't trip the filter,
    /// which is the right failure direction.
    nonisolated static let minBiasEchoTerms = 3

    /// Lowercased letter/digit word tokens — the unit both the term
    /// list and the candidate segment are compared in, so punctuation
    /// and casing can't hide an echo or fake one.
    nonisolated static func biasWordTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// True when `text` is the decoder reading the bias prompt back out
    /// — Whisper's documented `initial_prompt` failure on a
    /// low-information span. In dictation that costs one bad paste; in
    /// a meeting it lands mid-conversation attributed to a speaker.
    ///
    /// `terms` holds the word tokens of each term that actually reached
    /// the decoder, in prompt order. A segment counts as an echo only
    /// when its ENTIRE token sequence is exactly `minBiasEchoTerms` or
    /// more consecutive terms from that list, concatenated in order —
    /// no extra words before, after, or in between. Anything a person
    /// would plausibly say fails at least one of those.
    nonisolated static func looksLikeBiasEcho(_ text: String, terms: [[String]]) -> Bool {
        guard terms.count >= minBiasEchoTerms else { return false }
        let tokens = biasWordTokens(text)
        guard !tokens.isEmpty else { return false }

        for start in terms.indices {
            var cursor = 0
            var matchedTerms = 0
            var index = start
            while index < terms.count {
                let term = terms[index]
                let end = cursor + term.count
                guard end <= tokens.count,
                      Array(tokens[cursor..<end]) == term else { break }
                cursor = end
                matchedTerms += 1
                index += 1
                // The run has to account for the WHOLE segment — a
                // sentence that merely opens with three terms is still
                // a sentence.
                if cursor == tokens.count {
                    return matchedTerms >= minBiasEchoTerms
                }
            }
        }
        return false
    }

    // MARK: - VAD pre-pass

    /// What `runVADPrepass` returns: either concrete sample ranges
    /// inside the input buffer (when VAD found speech) or a sentinel
    /// "use the whole buffer" span (when VAD isn't loaded / errored).
    /// An empty array means VAD ran and found no speech.
    private struct SpeechSpan {
        let startSample: Int
        let endSample: Int
        let isFullBuffer: Bool

        static let fullBuffer = SpeechSpan(startSample: 0, endSample: 0, isFullBuffer: true)
    }

    /// Run Silero VAD on the input buffer and return the speech-only
    /// spans. Returns `[.fullBuffer]` (single sentinel) if VAD isn't
    /// available — that preserves v1.0 behaviour as a graceful
    /// fallback. Returns `[]` if VAD ran but found no speech.
    private func runVADPrepass(samples: [Float]) async -> [SpeechSpan] {
        #if canImport(FluidAudio)
        guard let vadBox else {
            // VAD still loading or load failed — fall back to
            // legacy full-buffer Whisper path.
            return [.fullBuffer]
        }
        // FluidAudio's VadSegmentationConfig knobs are in seconds
        // (TimeInterval). Defaults below cross-validated from the
        // Silero Python community ranges, adjusted for meeting
        // capture: a slightly more permissive minSpeechDuration so
        // we don't drop short backchannels ("yes"), a longer
        // minSilenceDuration so we don't fragment phrasing across
        // breath pauses, and modest padding so word edges aren't
        // shaved off by the gate.
        var cfg = VadSegmentationConfig.default
        cfg.minSpeechDuration  = 0.25     // 250 ms
        cfg.minSilenceDuration = 0.50     // 500 ms
        cfg.speechPadding      = 0.20     // 200 ms each side
        cfg.maxSpeechDuration  = 14.0     // Whisper-friendly cap

        do {
            let segments = try await vadBox.vad.segmentSpeech(samples, config: cfg)
            return segments.map { vs in
                let start = Int(vs.startTime * Self.audioSampleRate)
                let end   = Int(vs.endTime   * Self.audioSampleRate)
                return SpeechSpan(startSample: start, endSample: end, isFullBuffer: false)
            }
        } catch {
            log.error("VAD segmentSpeech failed (using full buffer): \(error.localizedDescription, privacy: .public)")
            return [.fullBuffer]
        }
        #else
        return [.fullBuffer]
        #endif
    }

    nonisolated private static let audioSampleRate: Double = 16_000

    /// Exact-match blocklist of frequent Whisper hallucinations seeded
    /// from YouTube subtitles. Covers the three languages we expect
    /// most ("en", "ru", "ja") plus universal music/applause markers.
    /// Curated from upstream issues and from QA observations
    /// (2026-05-18: tape-and-fan noise produced 8 consecutive
    /// "チョコレートを作る" lines on a quiet desk recording).
    nonisolated static func isKnownHallucination(_ text: String) -> Bool {
        return Self.hallucinationBlocklist.contains(text)
    }

    nonisolated static let hallucinationBlocklist: Set<String> = [
        // Japanese — YouTube outro phrases
        "チョコレートを作る",
        "チョコレートを作る。",
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございました。",
        "ご視聴ありがとうございます",
        "ご視聴ありがとうございます。",
        "ありがとうございました",
        "ありがとうございました。",
        "ありがとうございます",
        "ありがとうございます。",
        "バイバイ",
        "バイバイ。",
        "次回もお楽しみに",
        "次回もお楽しみに。",
        "見てくださってありがとうございました",
        "また次の動画でお会いしましょう",
        "フレッシュ",

        // English — channel-outro boilerplate
        "Thanks for watching!",
        "Thanks for watching.",
        "Thanks for watching",
        "Thank you for watching!",
        "Thank you for watching.",
        "Thank you for watching",
        "Please subscribe to my channel.",
        "Please subscribe to my channel",
        "Subscribe to the channel.",
        "Subscribe to the channel",
        "Don't forget to subscribe!",
        "Don't forget to subscribe",
        "Like and subscribe!",
        "Like and subscribe",
        "Bye.",
        "Bye!",
        "Bye-bye.",
        "Bye-bye!",
        "you",
        "You",
        "Thank you.",
        "Thank you!",

        // Russian — known fansub/subtitler artefacts
        "Спасибо за внимание.",
        "Спасибо за внимание!",
        "Спасибо за внимание",
        "Продолжение следует...",
        "Продолжение следует…",
        "Субтитры делал DimaTorzok",
        "Субтитры сделал DimaTorzok",
        "Субтитры создавал DimaTorzok",
        "Корректор субтитров А.Семкин",
        "Редактор субтитров А.Семкин",

        // Universal sound-effect markers
        "[Music]",
        "[music]",
        "[MUSIC]",
        "[Music playing]",
        "[Applause]",
        "[applause]",
        "[Laughter]",
        "[laughter]",
        "[Inaudible]",
        "♪",
        "♪♪",
        "♪♪♪",
        "(music)",
        "(applause)",
    ]
}

/// Sendable wrapper around the non-Sendable WhisperKit class so we can
/// stash it in a property accessed across actor hops.
final class WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

#if canImport(FluidAudio)
/// Sendable wrapper around the actor-isolated `VadManager` so we can
/// stash it as a property on `WhisperEngine` (also actor-isolated)
/// without Sendable complaints. `VadManager` itself is already an
/// actor, so its API stays safe across actor hops.
final class VadManagerBox: @unchecked Sendable {
    let vad: VadManager
    init(_ vad: VadManager) { self.vad = vad }
}
#endif

/// One utterance returned by Whisper, with times in seconds relative to
/// the start of the buffer it was transcribed from.
struct WhisperSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

nonisolated enum WhisperEngineError: LocalizedError {
    case notReady
    case unsupportedModel(String)
    case notEnoughDiskSpace
    var errorDescription: String? {
        switch self {
        case .notReady: return String(localized: "Whisper model isn't loaded yet. Open Settings → Transcription.")
        case .unsupportedModel(let id):
            return String(localized: "The transcription model \(id) is not supported.")
        case .notEnoughDiskSpace:
            return String(localized: "There is not enough free disk space to download the selected transcription model.")
        }
    }
}
