//
//  StorageUsage.swift
//  Daisy
//
//  "How much disk does Daisy use, and where is it?" — one answer, for
//  Settings → General → Storage.
//
//  Two numbers, deliberately kept apart:
//    • recordings — everything under the ACTIVE recordings root
//      (`<base>/Daisy/Sessions`): audio archives, transcripts,
//      summaries, screenshots. This is user data.
//    • models — the ASR / diarization weights Daisy downloaded. This is
//      reclaimable cache; the Transcription tab has the button that
//      reclaims it.
//
//  Only the ACTIVE recordings root is measured. Folders left behind in
//  a previous location ("Leave them where they are") stay visible in the
//  Library but are NOT counted here: this figure sits directly under the
//  path of the folder it describes, and a total that silently included
//  directories somewhere else would make that pairing a lie.
//
//  Everything that touches the filesystem is `nonisolated` and reached
//  through `Task.detached` — a recordings root with thousands of
//  sessions is a multi-second `stat` walk, and this runs while the
//  Settings window is drawing. (`nonisolated async` alone would NOT
//  leave the caller's executor under SE-0461 / approachable concurrency,
//  hence the explicit detach.)
//

import Foundation

/// Disk footprint at one point in time. Bytes only: the counts users
/// actually act on are already on their own rows ("Delete recordings"
/// carries the recording count, the Transcription tab carries the model
/// count), and repeating them here just invites two numbers to disagree.
struct StorageUsageSnapshot: Sendable {
    var recordingBytes: Int64
    var modelBytes: Int64
    /// False when the configured recordings folder isn't there at all —
    /// an external disk that's unplugged, a synced folder that hasn't
    /// come back. Reporting "0 bytes" for that would read as "your
    /// recordings are gone", which is the one thing it must not say.
    var recordingsReachable: Bool
}

@MainActor
enum StorageUsage {
    /// Last measurement + when it was taken. A tab switch re-runs the
    /// view's `.task`, and re-walking gigabytes every time the user
    /// glances at Settings is wasteful, so a recent result is reused.
    private static var cached: (snapshot: StorageUsageSnapshot, at: Date)?
    /// The scan currently running, if any. Two callers arriving together
    /// (Settings opening while a bump is in flight) share one walk
    /// instead of racing two.
    private static var inFlight: Task<StorageUsageSnapshot, Never>?
    /// Bumped by `invalidate()`. A walk that started before the bump
    /// measured a world that no longer exists (the folder moved, the
    /// audio was purged), so its result must not be written back into
    /// the cache — otherwise the stale figure sticks for another minute
    /// under the NEW path.
    private static var generation = 0

    /// How long a measurement is considered fresh enough to reuse.
    private static let maxAge: TimeInterval = 60

    /// Measure, or return a recent measurement. Call `invalidate()` after
    /// anything that changes the footprint (folder change, audio purge,
    /// bulk delete) so the next read re-walks.
    static func snapshot() async -> StorageUsageSnapshot {
        if let cached = cached, Date().timeIntervalSince(cached.at) < maxAge {
            return cached.snapshot
        }
        if let inFlight = inFlight {
            return await inFlight.value
        }
        let base = activeBase()
        // The ticket must outlive the scan: on a user-picked folder it
        // holds the security scope the walk reads through. Captured by
        // the task, released when the task finishes.
        let ticket = base.flatMap { SessionsFolder.acquireAccess(to: $0) }
        let root = base.map { SessionsFolder.sessionsDirectory(in: $0) }
        let reachable = base.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let generationAtStart = generation
        let task = Task<StorageUsageSnapshot, Never> {
            // Two independent trees — walk them concurrently rather than
            // making the model scan wait behind a large recordings root.
            // `async let` alone would NOT leave the main actor here (the
            // child task inherits this task's isolation), hence the
            // explicit detach inside each one.
            async let recordingsTask = Task.detached { directoryBytes(at: root) }.value
            async let modelsTask = Task.detached { modelBytes() }.value
            let recordings = await recordingsTask
            let models = await modelsTask
            ticket?.release()
            return StorageUsageSnapshot(
                recordingBytes: recordings,
                modelBytes: models,
                recordingsReachable: reachable
            )
        }
        inFlight = task
        let result = await task.value
        guard generationAtStart == generation else { return result }
        inFlight = nil
        cached = (result, Date())
        return result
    }

    /// Drop the cached measurement so the next `snapshot()` re-walks.
    /// Also disowns any scan already in flight: it's measuring the state
    /// we just changed, so its answer is wrong before it arrives.
    static func invalidate() {
        generation &+= 1
        cached = nil
        inFlight = nil
    }

    // MARK: - Where the recordings are

    /// The base folder new recordings are written under, or nil when the
    /// user HAS chosen one and it can't be resolved right now (unplugged
    /// disk, folder deleted).
    ///
    /// Deliberately NOT `SessionsFolder.acquireBase()`: that falls back
    /// to the default container so a recording can still be saved
    /// somewhere, which is right for recording and wrong for reporting.
    /// A size and a path that quietly describe a folder the user never
    /// chose are worse than an honest "can't reach it" — that fallback
    /// is exactly what makes a missing-recordings report unreadable.
    private static func activeBase() -> URL? {
        if SessionsFolder.hasUserFolder {
            return SessionsFolder.resolveUserFolder()
        }
        return defaultContainerBase()
    }

    /// `SessionsFolder.defaultBase()` without the `create: true` — this
    /// path feeds display and diagnostics, and neither should be able to
    /// bring a directory into existence as a side effect. The URL is
    /// returned whether or not it exists; callers check.
    nonisolated private static func defaultContainerBase() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    /// The directory recordings actually land in — the base folder plus
    /// `Daisy/Sessions`. Shown verbatim in Settings (tilde-abbreviated)
    /// because "Inside Daisy's container" told a user with a missing
    /// recording nothing they could act on.
    ///
    /// Resolution only, no file I/O beyond the bookmark resolve.
    static func recordingsDirectory() -> URL? {
        activeBase().map { SessionsFolder.sessionsDirectory(in: $0) }
    }

    /// Tilde-abbreviated path for the Settings row. nil means "there is
    /// no path to show": either the chosen folder isn't reachable, or
    /// even Application Support wouldn't resolve. The caller decides
    /// which of those two sentences to print — it knows, from
    /// `SessionsFolder.hasUserFolder`, whether a folder was ever chosen.
    static func recordingsDisplayPath() -> String? {
        recordingsDirectory().map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    /// What "Reveal in Finder" should select: the sessions directory
    /// once it exists, otherwise the folder that will contain it, and
    /// nil when neither is on disk (unplugged volume) so the caller can
    /// say so instead of opening a Finder window onto nothing.
    ///
    /// Never creates anything — an empty `Daisy/Sessions` conjured by a
    /// diagnostic button is exactly the kind of stray directory the husk
    /// cleanup then has to reason about. Same base resolution as
    /// `recordingsDirectory()`, so the button and the displayed path can
    /// never point at different folders.
    ///
    /// The scope ticket is released before the caller hands the URL to
    /// Finder. Safe today (Daisy ships un-sandboxed, so the scope is a
    /// formality); if the app is ever sandboxed, the reveal has to hold
    /// the ticket across the `NSWorkspace` call instead.
    static func revealTarget() -> URL? {
        guard let base = activeBase() else { return nil }
        let ticket = SessionsFolder.acquireAccess(to: base)
        defer { ticket?.release() }
        let fm = FileManager.default
        let sessions = SessionsFolder.sessionsDirectory(in: base)
        if fm.fileExists(atPath: sessions.path) { return sessions }
        return fm.fileExists(atPath: base.path) ? base : nil
    }

    // MARK: - Scanning (off the main actor)

    /// Recursive byte total of regular files under `url`. Unreadable
    /// subtrees are skipped rather than aborting the walk — a partial
    /// number beats no number on a diagnostics row.
    ///
    /// iCloud-evicted files still report their real size through
    /// `.fileSizeKey` (the metadata stays local), so a synced folder
    /// reports what it would occupy once downloaded — which is the
    /// number the user cares about. Reading sizes never materializes
    /// content, so this cannot trigger a download.
    nonisolated private static func directoryBytes(at url: URL?) -> Int64 {
        guard let url else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
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

    /// Every model weight Daisy put on disk:
    ///   • Whisper variants under `WhisperEngine`'s cache root (which
    ///     still resolves to the legacy `~/Documents` location when the
    ///     one-shot migration couldn't run — see WhisperEngine);
    ///   • the whole FluidAudio model root, which holds the Parakeet
    ///     dictation model AND the diarization / VAD models. Counting
    ///     the root rather than the Parakeet folders alone is the
    ///     difference between "1.2 GB" and the truth.
    ///
    /// Apple's SpeechAnalyzer models are deliberately absent: macOS owns
    /// them, they're shared with every other app, and no button in Daisy
    /// can free them.
    nonisolated private static func modelBytes() -> Int64 {
        var total = WhisperEngine.totalCacheSizeBytes()
        if let fluid = fluidAudioModelsRoot() {
            total += directoryBytes(at: fluid)
        }
        return total
    }

    /// FluidAudio's on-disk cache root — `~/Library/Application Support/
    /// FluidAudio/Models/`. Mirrors the root `ParakeetEngine` filters
    /// for its own folders; kept as a separate reader because here we
    /// want the whole tree, diarizer included.
    nonisolated private static func fluidAudioModelsRoot() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let root = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        return fm.fileExists(atPath: root.path) ? root : nil
    }
}
