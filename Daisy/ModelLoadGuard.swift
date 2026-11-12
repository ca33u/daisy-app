//
//  ModelLoadGuard.swift
//  Daisy
//
//  Remembers across launches that a Core ML model was being loaded, so the
//  next launch can tell that the last run ended inside that load.
//
//  Sentry DAISY-MAC-4 (12.11, Daisy 1.0.8.49 on a MacBook Air M2, macOS
//  15.3.1, twice in 28 minutes on one Mac). What the report shows, and all
//  it shows:
//   • the thread that died: SIGABRT, `__assert_rtn` under
//     `+[MPSGraphPackage readResources:fromURL:usingAllocator:]`, reading an
//     already-compiled package from the app's Core ML cache, reached from
//     `+[MLModel loadContentsOfURL:configuration:completionHandler:]` — the
//     load WhisperKit starts (`WhisperEngine.loadKit`);
//   • at the same moment another thread was in FluidAudio's
//     `ModelHub.loadModelsOnce` → `MLModel(contentsOf:)`, in Core ML's
//     on-device compilation of a model.
//  Why the read failed is not established. The framework aborts instead of
//  throwing, so no `do/catch` sees it, and the launch preload starts seconds
//  after launch: a package that stays unreadable would end Daisy at every
//  launch.
//
//  So every in-process Core ML load is bracketed by a small marker file
//  (`run`), one per engine, written right before the load and resolved when
//  it returns or throws; a normal quit clears this process's markers. A
//  marker that outlives its process means that run ended in that load
//  (`checkAtLaunch`, before the session is made). What follows depends on
//  how it ended:
//   • however it ended — a crash, a Force Quit, a power cut: the app's
//     compiled-model cache (`<Caches>/<bundle id>/
//     com.apple.e5rt.e5bundlecache`, that one folder and nothing beside it)
//     is moved aside and deleted, so the models compile again — whether a
//     compile cut short can leave a package that doesn't read is not known,
//     and it can't be ruled out — and the launch preload is skipped for
//     this launch. Not the purge while another Daisy is running: its models
//     came from that folder. A marker written while a FluidAudio download
//     window was open (the library downloads and loads in one call) only
//     skips the preload: that run was most likely downloading.
//   • the engine gets a strike unless that run is on record as NOT having
//     crashed. The record is Sentry's (`CrashReports.lastRun`), and it
//     speaks for a marker's run only if Sentry's crash handler was in that
//     run — the marker says so (`InFlight.crashHandlerInstalled`). Handler
//     there and no crash recorded: a Force Quit, a kill, a power cut — no
//     strike. A crash recorded: a strike. No record either way — crash
//     reports on «Never send», the handler not in that run, Sentry with no
//     answer: a strike too, since the death can't be told from a crash and
//     someone in a crash loop who turned the reports off needs the hold
//     most. A strike counts for the build that died and for a week
//     (`ModelLoadGuardPolicy.strikeLifetime`).
//  At `ModelLoadGuardPolicy.holdAfter` strikes the engine is HELD: its
//  loader refuses to load and shows why, as Whisper does on an Intel Mac
//  (`WhisperEngine.ensureLoaded`), until the person asks for the models
//  again («Download and check», «Download speech model again», another
//  meeting model, «Download models now») or another build of Daisy runs.
//  Other things load models at launch with no click — the import queue,
//  interrupted-recording recovery, a reconnect retry, Settings → Dictation
//  appearing — so skipping the preload alone would not end the loop; the
//  hold is checked inside the engines. A load that succeeds clears the
//  strikes.
//
//  One more rule, for a Mac that 1.0.8.49 or 1.0.8.50 already ended on:
//  those builds wrote no markers, so the first launch of a build with the
//  guard would find nothing and preload from the same compiled cache. The
//  first launch with the guard — the marker folder isn't there yet — that
//  follows a run on record as crashed moves the compiled cache aside too
//  (not while another Daisy runs). Nothing says that crash was in a load,
//  so there is no strike and the preload is not skipped; if it dies again,
//  the marker it leaves takes over from there.
//
//  Where the markers live:
//   • a Release build: `~/Library/Application Support/Daisy/model-load-guard`;
//   • the test host (`TestHost.isActive`): nowhere — the guard is inert, and
//     tests make their own on a temporary folder;
//   • a Debug build: nowhere, unless the environment variable
//     `DAISY_MODEL_LOAD_GUARD_DIR` names a folder, which is then used. A
//     developer stopping a Debug run in the middle of a load is a kill
//     mid-load and must never cost the installed app its compiled cache;
//     the variable lets the mechanics be tried by hand apart from the
//     installed app's markers. (The compiled cache is still the running
//     bundle id's own.)
//
//  The bookkeeping never blocks or fails a load: a marker that can't be
//  written is logged once and the load goes on.
//

import AppKit
import Darwin
import Foundation
import Observation
import os

/// One marker per engine. The raw value is the marker's file name.
nonisolated enum ModelLoadEngine: String, CaseIterable, Codable, Sendable {
    /// The meeting model (`WhisperEngine.performLoad`).
    case whisper
    /// A model chosen for one re-transcription (`WhisperEngine.alternateModelBox`).
    case whisperJob
    case parakeet
    /// Silero VAD.
    case speechDetection
    case diarizer
    case nemotron

    /// The engine as it reads after «while loading» — in Russian after
    /// «пока загружала», the accusative, which is why these are keyed and
    /// not the names used elsewhere («speaker separation» is taken in the
    /// genitive).
    var nameAfterLoading: String {
        switch self {
        case .whisper, .whisperJob:
            String(localized: "modelLoad.name.whisper", defaultValue: "the speech model")
        case .parakeet:
            String(localized: "modelLoad.name.parakeet", defaultValue: "the fast dictation model")
        case .speechDetection:
            String(localized: "modelLoad.name.speechDetection", defaultValue: "speech detection")
        case .diarizer:
            String(localized: "modelLoad.name.diarizer", defaultValue: "speaker separation")
        case .nemotron:
            String(localized: "modelLoad.name.nemotron", defaultValue: "the live dictation model")
        }
    }
}

/// The decisions, with no file or process in them — what the tests pin.
nonisolated enum ModelLoadGuardPolicy {
    /// Crashes in a row inside one engine's load before it is held.
    static let holdAfter = 2
    /// How long a strike short of a hold counts: «two in a row» is not one
    /// in March and one in November.
    static let strikeLifetime: TimeInterval = 7 * 24 * 60 * 60

    static let compiledCacheFolderName = "com.apple.e5rt.e5bundlecache"
    /// What a moved-aside cache is called until it is deleted:
    /// `com.apple.e5rt.e5bundlecache.daisy-purge-<UUID>`.
    static let movedAsideInfix = ".daisy-purge-"
    static let directoryVariable = "DAISY_MODEL_LOAD_GUARD_DIR"

    struct InFlight: Equatable, Codable, Sendable {
        var pid: Int32
        var startedAt: Date
        /// The build that started the load: a strike is that build's.
        var build: String
        /// Started while a FluidAudio download window was open: FluidAudio
        /// downloads and loads in one call, so this may be minutes of
        /// network and not a load.
        var mayDownload = false
        /// Sentry's crash handler was in this process
        /// (`CrashReports.handlerInstalled`): only then does Sentry's
        /// record of the last run say anything about this one.
        var crashHandlerInstalled = false
    }

    struct Record: Equatable, Codable, Sendable {
        var strikes = 0
        /// The build whose crashes the strikes count, and when the last
        /// one was counted. Nil while there are none.
        var strikesBuild: String?
        var lastStrikeAt: Date?
        var loading: InFlight?

        /// Nothing to keep: no file.
        var isEmpty: Bool { strikes == 0 && loading == nil }

        fileprivate mutating func dropStrikes() {
            strikes = 0
            strikesBuild = nil
            lastStrikeAt = nil
        }
    }

    struct LaunchPlan: Equatable, Sendable {
        /// Every record as it stands after this launch's count. An empty
        /// one means its file goes.
        var records: [ModelLoadEngine: Record] = [:]
        /// A marker was there and its process is gone.
        var died: Set<ModelLoadEngine> = []
        /// The ones among `died` that got a strike.
        var struck: Set<ModelLoadEngine> = []
        var purgeCompiledCache = false
        /// The purge was due and another Daisy is running: not done.
        var purgeWithheld = false
        /// The purge is the first launch's (`firstLaunchWithGuard`), not a
        /// dead marker's.
        var firstLaunchPurge = false
        var skipPreload = false
        var held: Set<ModelLoadEngine> = []
        /// Held as of this launch: the ones to tell the person about.
        var announce: Set<ModelLoadEngine> = []
    }

    /// `record` with the strikes that no longer count taken off: another
    /// build's — a hold set by one build must not outlive it — and, short
    /// of a hold, ones older than `strikeLifetime`. A hold itself doesn't
    /// age: it ends with the person's ask or with another build.
    static func unexpired(_ record: Record, build: String, now: Date) -> Record {
        var next = record
        guard next.strikes > 0 else {
            next.dropStrikes()
            return next
        }
        if next.strikesBuild != build {
            next.dropStrikes()
        } else if next.strikes < holdAfter,
                  now.timeIntervalSince(next.lastStrikeAt ?? .distantPast) > strikeLifetime {
            next.dropStrikes()
        }
        return next
    }

    /// What is known of how the run that left `flight` ended. Sentry's
    /// record counts only when its handler was in that run; a marker from
    /// before the field existed, or from a run with crash reports off, has
    /// no record.
    static func evidence(for flight: InFlight, lastRun: CrashReports.LastRun) -> CrashReports.LastRun {
        flight.crashHandlerInstalled ? lastRun : .unknown
    }

    /// `isAlive`: the marker's process is another Daisy still running (the
    /// language switch starts the new instance before the old one quits).
    /// Its marker is its own and is left as it is.
    ///
    /// `lastRun`: Sentry's record of the last run (`CrashReports.lastRun`).
    /// A dead marker is struck unless its run is on record as not having
    /// crashed (`evidence`): two Force Quits with the handler watching must
    /// not end with recording refused, and a death nobody recorded can't be
    /// told from a crash.
    ///
    /// `anotherInstanceRunning`: a Daisy other than this process is up. Its
    /// models were loaded from the compiled cache, so the folder is not
    /// moved from under it; the preload is skipped all the same.
    ///
    /// `firstLaunchWithGuard`: the marker folder wasn't there yet — no run
    /// on this Mac has had the guard. 1.0.8.49 and 1.0.8.50 wrote no
    /// markers, so a Mac those builds ended on (Sentry DAISY-MAC-4) would
    /// get its first guarded launch with nothing to find and a preload
    /// reading the same compiled cache. If the last run is on record as
    /// crashed, the cache is purged on that launch as well. Only that: no
    /// strike and no skipped preload — nothing says the crash was in a
    /// load, and a preload that dies again leaves a marker for the rules
    /// above. Not on record as crashed, or no record: nothing.
    static func atLaunch(_ found: [ModelLoadEngine: Record], isAlive: (Int32) -> Bool,
                         lastRun: CrashReports.LastRun, build: String, now: Date,
                         anotherInstanceRunning: Bool = false,
                         firstLaunchWithGuard: Bool = false) -> LaunchPlan {
        var plan = LaunchPlan()
        var purgeDue = false
        for (engine, stored) in found {
            var record = unexpired(stored, build: build, now: now)
            if let flight = record.loading, !isAlive(flight.pid) {
                record.loading = nil
                plan.died.insert(engine)
                plan.skipPreload = true
                // Inside a download window the run was most likely
                // downloading: nothing compiled is in doubt, no strike.
                if !flight.mayDownload {
                    purgeDue = true
                    // Another build's death is not this build's strike.
                    if evidence(for: flight, lastRun: lastRun) != .didNotCrash, flight.build == build {
                        record.strikes += 1
                        record.strikesBuild = build
                        record.lastStrikeAt = now
                        plan.struck.insert(engine)
                    }
                }
            }
            plan.records[engine] = record
            if record.strikes >= holdAfter { plan.held.insert(engine) }
        }
        let firstLaunchPurgeDue = firstLaunchWithGuard && lastRun == .crashed && !purgeDue
        plan.purgeCompiledCache = (purgeDue || firstLaunchPurgeDue) && !anotherInstanceRunning
        plan.purgeWithheld = (purgeDue || firstLaunchPurgeDue) && anotherInstanceRunning
        plan.firstLaunchPurge = firstLaunchPurgeDue && !anotherInstanceRunning
        plan.announce = plan.held.intersection(plan.struck)
        return plan
    }

    /// The record while `flight` loads. Strikes carry over.
    static func whileLoading(_ record: Record?, flight: InFlight) -> Record {
        var next = record ?? Record()
        next.loading = flight
        return next
    }

    /// The record once this process's load is over; nil — nothing left to
    /// keep, the file goes. A load that worked clears the strikes; one that
    /// threw proves nothing either way and keeps them. A marker another
    /// Daisy wrote meanwhile stays that Daisy's.
    static func afterLoad(_ record: Record?, succeeded: Bool, pid: Int32) -> Record? {
        var next = record ?? Record()
        if next.loading?.pid == pid { next.loading = nil }
        if succeeded { next.dropStrikes() }
        return next.isEmpty ? nil : next
    }

    /// The person asked for the models again: one strike short of a hold,
    /// so the engine loads — at later launches too — and the next crash in
    /// its load holds it again. The strike that stays is dated `now`: left
    /// with the hold's own date, one lifted after more than a week would
    /// lose it at the next launch, and that crash would count as the first.
    static func afterLift(_ record: Record, now: Date) -> Record? {
        var next = record
        next.strikes = min(next.strikes, holdAfter - 1)
        if next.strikes <= 0 {
            next.dropStrikes()
        } else {
            next.lastStrikeAt = now
        }
        return next.isEmpty ? nil : next
    }

    /// The record after a normal quit of process `pid`: its own marker
    /// goes, however long the load has been running — a quit in the middle
    /// of a load is not a death. Equal to `record` when there is nothing of
    /// ours to clear; nil — the file goes.
    static func atTermination(_ record: Record, pid: Int32) -> Record? {
        guard record.loading?.pid == pid else { return record }
        var next = record
        next.loading = nil
        return next.isEmpty ? nil : next
    }

    /// The app's compiled-model cache. Nil without a bundle id: the path
    /// would then be `<Caches>/com.apple.e5rt.e5bundlecache`, a folder that
    /// exists and is not ours.
    static func compiledCacheURL(cachesRoot: URL, bundleID: String?) -> URL? {
        guard let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bundleID.contains("/"), bundleID != ".", bundleID != ".." else { return nil }
        return cachesRoot.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(compiledCacheFolderName, isDirectory: true)
    }

    /// Where the markers live, or nil for an inert guard (the file header).
    static func markerDirectory(isTestHost: Bool, isDebugBuild: Bool,
                                environment: [String: String], applicationSupport: URL?) -> URL? {
        if isTestHost { return nil }
        if isDebugBuild {
            guard let path = environment[directoryVariable], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return applicationSupport?.appendingPathComponent("Daisy/model-load-guard", isDirectory: true)
    }
}

extension ModelLoadGuardPolicy.InFlight {
    /// A marker written before a field existed reads it as false.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pid = try values.decode(Int32.self, forKey: .pid)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        build = try values.decode(String.self, forKey: .build)
        mayDownload = try values.decodeIfPresent(Bool.self, forKey: .mayDownload) ?? false
        crashHandlerInstalled = try values.decodeIfPresent(Bool.self, forKey: .crashHandlerInstalled) ?? false
    }
}

/// The markers on disk: `<directory>/<engine>.json`, written atomically. A
/// nil directory makes every call a no-op. No fsync: a process that aborts
/// loses nothing the kernel already has; only a power cut would.
nonisolated final class ModelLoadMarkerStore: Sendable {
    typealias Record = ModelLoadGuardPolicy.Record

    let directory: URL?

    init(directory: URL?) { self.directory = directory }

    var isActive: Bool { directory != nil }

    /// The marker folder is there: some launch on this Mac has run the
    /// guard before (`ModelLoadGuardPolicy.atLaunch`, `firstLaunchWithGuard`).
    var directoryExists: Bool {
        guard let directory else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// False when the folder isn't there and couldn't be made.
    @discardableResult
    func createDirectory() -> Bool {
        guard let directory else { return true }
        return (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
    }

    private func url(_ engine: ModelLoadEngine) -> URL? {
        directory?.appendingPathComponent("\(engine.rawValue).json")
    }

    /// A file that isn't there or can't be read as a record is no record.
    func read(_ engine: ModelLoadEngine) -> Record? {
        guard let url = url(engine), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Record.self, from: data)
    }

    func readAll() -> [ModelLoadEngine: Record] {
        var all: [ModelLoadEngine: Record] = [:]
        for engine in ModelLoadEngine.allCases {
            if let record = read(engine) { all[engine] = record }
        }
        return all
    }

    /// False when the record couldn't be written.
    @discardableResult
    func write(_ record: Record, for engine: ModelLoadEngine) -> Bool {
        guard let directory, let url = url(engine) else { return true }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// False when a file is there and couldn't be removed.
    @discardableResult
    func remove(_ engine: ModelLoadEngine) -> Bool {
        guard let url = url(engine), FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// `record`, or no file for nil and for a record with nothing in it.
    @discardableResult
    func put(_ record: Record?, for engine: ModelLoadEngine) -> Bool {
        if let record, !record.isEmpty { return write(record, for: engine) }
        return remove(engine)
    }
}

/// The one deletion: the app's compiled-model cache, by rename and then
/// remove, so a launch never loads from a folder that is half gone.
nonisolated enum CompiledModelCache {
    /// Only a folder with the compiled cache's name, inside a folder of
    /// its own — never one sitting directly in a `Caches` folder, which is
    /// where the path lands without a bundle id and is not the app's.
    static func isAppsOwn(_ folder: URL) -> Bool {
        folder.lastPathComponent == ModelLoadGuardPolicy.compiledCacheFolderName
            && folder.deletingLastPathComponent().lastPathComponent != "Caches"
    }

    /// Renames `folder` to a sibling to be deleted. Nil when there is
    /// nothing to move, the rename failed, or `folder` isn't the app's
    /// compiled cache (`isAppsOwn`) — nothing else is ever moved.
    static func moveAside(_ folder: URL) -> URL? {
        guard isAppsOwn(folder), FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let aside = folder.deletingLastPathComponent().appendingPathComponent(
            folder.lastPathComponent + ModelLoadGuardPolicy.movedAsideInfix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: folder, to: aside)
            return aside
        } catch {
            return nil
        }
    }

    /// Deletes the moved-aside copies beside `folder`: this launch's, and
    /// one an earlier launch didn't live to delete. Disk work — call it off
    /// the main thread. Returns how many it removed.
    @discardableResult
    static func removeMovedAside(beside folder: URL) -> Int {
        guard isAppsOwn(folder) else { return 0 }
        let parent = folder.deletingLastPathComponent()
        let prefix = folder.lastPathComponent + ModelLoadGuardPolicy.movedAsideInfix
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            if (try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}

/// What a held engine throws at a job that asked for it
/// (`WhisperEngine.transcribe`, `alternateModelBox`).
nonisolated struct ModelLoadHeldError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class ModelLoadGuard {
    typealias Policy = ModelLoadGuardPolicy

    static let shared = ModelLoadGuard(
        store: ModelLoadMarkerStore(directory: Policy.markerDirectory(
            isTestHost: TestHost.isActive,
            isDebugBuild: isDebugBuild,
            environment: ProcessInfo.processInfo.environment,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)),
        compiledCache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .flatMap { Policy.compiledCacheURL(cachesRoot: $0, bundleID: Bundle.main.bundleIdentifier) }
    )

    private static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Engines that don't load until the person asks. Observed: the
    /// preparation card in Settings shows while there is one.
    private(set) var held: Set<ModelLoadEngine> = []
    /// The last run ended in a load: nothing is preloaded this launch.
    private(set) var skipsLaunchPreload = false
    /// Held as of this launch, in `ModelLoadEngine`'s order.
    private(set) var announced: [ModelLoadEngine] = []

    @ObservationIgnored private let store: ModelLoadMarkerStore
    @ObservationIgnored private let compiledCache: URL?
    @ObservationIgnored private let pid: Int32
    @ObservationIgnored private let build: String
    @ObservationIgnored private let isAlive: (Int32) -> Bool
    @ObservationIgnored private let lastRun: () -> CrashReports.LastRun
    @ObservationIgnored private let crashHandlerInstalled: () -> Bool
    @ObservationIgnored private let anotherInstanceRunning: () -> Bool
    @ObservationIgnored private let downloadWindowIsOpen: @MainActor () -> Bool
    @ObservationIgnored private let checkFiles: @MainActor (ModelLoadEngine) async -> Void
    @ObservationIgnored private let afterLift: @MainActor (Set<ModelLoadEngine>) -> Void
    /// Loads of one engine running at once in this process (possible after
    /// a cancelled download drops the engine's task): the marker goes when
    /// the last of them ends, and one that worked is enough to clear the
    /// strikes.
    @ObservationIgnored private var inFlight: [ModelLoadEngine: (count: Int, succeeded: Bool)] = [:]
    @ObservationIgnored private var saidUnwritable = false
    /// A check-then-lift under way (`liftHoldsBeforeLoading`).
    @ObservationIgnored private var liftTask: Task<Void, Never>?
    /// The delete of a moved-aside cache, for tests to wait on.
    @ObservationIgnored private(set) var cleanup: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "ModelLoadGuard")

    /// The defaults are the app's; tests replace every one that reaches
    /// outside the guard's own folder.
    init(store: ModelLoadMarkerStore,
         compiledCache: URL?,
         pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         build: String? = nil,
         isAlive: @escaping (Int32) -> Bool = ModelLoadGuard.isAnotherRunningDaisy,
         lastRun: @escaping () -> CrashReports.LastRun = { CrashReports.lastRun },
         crashHandlerInstalled: @escaping () -> Bool = { CrashReports.handlerInstalled },
         anotherInstanceRunning: @escaping () -> Bool = ModelLoadGuard.anotherDaisyIsRunning,
         downloadWindowIsOpen: @escaping @MainActor () -> Bool = ModelLoadGuard.fluidAudioDownloadWindowIsOpen,
         checkFiles: @escaping @MainActor (ModelLoadEngine) async -> Void = ModelLoadGuard.checkFilesAgainstManifest,
         afterLift: @escaping @MainActor (Set<ModelLoadEngine>) -> Void = ModelLoadGuard.clearHeldFailures) {
        self.store = store
        self.compiledCache = compiledCache
        self.pid = pid
        self.build = build ?? "\(VersionInfo.marketingVersion) (\(VersionInfo.buildNumber))"
        self.isAlive = isAlive
        self.lastRun = lastRun
        self.crashHandlerInstalled = crashHandlerInstalled
        self.anotherInstanceRunning = anotherInstanceRunning
        self.downloadWindowIsOpen = downloadWindowIsOpen
        self.checkFiles = checkFiles
        self.afterLift = afterLift
    }

    static func fluidAudioDownloadWindowIsOpen() -> Bool {
        #if canImport(FluidAudio)
        return FluidAudioNetworkGuard.isDownloadWindowOpen
        #else
        return false
        #endif
    }

    // MARK: - Launch

    /// Once per process, from `DaisyApp.init`: after `CrashReports.start()`
    /// — its record of the last run decides whether a death is struck — and
    /// before the session and its preload exist and anything loads a model.
    /// Reads a handful of small files and, after a death, renames one
    /// folder — cheap enough for the main thread at launch. The deleting is
    /// not, and runs after.
    @discardableResult
    func checkAtLaunch(now: Date = Date()) -> Policy.LaunchPlan? {
        guard store.isActive else { return nil }
        // No marker folder yet: the first launch with the guard on this Mac
        // (`Policy.atLaunch`). Made below, so this is true once.
        let firstLaunch = !store.directoryExists
        var found = store.readAll()
        // Whose owner is gone. Nothing has loaded in this process yet, so a
        // marker carrying its own pid is a dead run's whose number came
        // round again (after a restart of the Mac). And a marker read a
        // moment before its owner quit normally is not a death: a quit
        // clears the marker before the process exits (the language switch
        // has two Daisys up at once), so only a marker still there AFTER
        // its owner was seen gone outlived it — it is read again.
        var gone: Set<Int32> = []
        for engine in ModelLoadEngine.allCases {
            var reads = 0
            while reads < 3, let flight = found[engine]?.loading, flight.pid == pid || !isAlive(flight.pid) {
                reads += 1
                let again = store.read(engine)
                if again?.loading == flight {
                    gone.insert(flight.pid)
                    break
                }
                found[engine] = again
            }
        }
        // Still changing after three reads: left for the next launch.
        let reported = lastRun()
        // Only asked when there is something to purge for.
        let purgeMayBeDue = found.values.contains { $0.loading.map { gone.contains($0.pid) } ?? false }
            || (firstLaunch && reported == .crashed)
        let anotherIsUp = purgeMayBeDue && anotherInstanceRunning()
        let plan = Policy.atLaunch(found, isAlive: { !gone.contains($0) }, lastRun: reported,
                                   build: build, now: now, anotherInstanceRunning: anotherIsUp,
                                   firstLaunchWithGuard: firstLaunch)
        // A folder that can't be made never fails the launch: the rule may
        // fire again next time, which costs a recompile.
        if firstLaunch, !store.createDirectory() { noteUnwritable() }
        for engine in ModelLoadEngine.allCases {
            let record = plan.records[engine]
            if plan.died.contains(engine), let was = found[engine]?.loading {
                let evidence = Policy.evidence(for: was, lastRun: reported)
                let outcome: String
                if plan.struck.contains(engine) {
                    outcome = "strike \(record?.strikes ?? 0), "
                        + (evidence == .crashed ? "a crash is on record" : "nothing on record says it didn't crash")
                } else if was.mayDownload {
                    outcome = "no strike, it may have been downloading"
                } else if evidence == .didNotCrash {
                    outcome = "no strike, that run is on record as not having crashed"
                } else {
                    outcome = "no strike, another build's"
                }
                log.error("The last run ended while loading \(engine.rawValue, privacy: .public) (build \(was.build, privacy: .public), pid \(was.pid, privacy: .public)) — \(outcome, privacy: .public)")
            }
            if record != found[engine], !store.put(record, for: engine) { noteUnwritable() }
        }
        held = plan.held
        skipsLaunchPreload = plan.skipPreload
        announced = ModelLoadEngine.allCases.filter { plan.announce.contains($0) }
        for engine in ModelLoadEngine.allCases where plan.held.contains(engine) {
            log.error("\(engine.rawValue, privacy: .public) is held after \(plan.records[engine]?.strikes ?? 0, privacy: .public) strikes — it loads again only when the person asks")
        }
        if plan.skipPreload {
            log.notice("Launch preload skipped for this launch")
        }
        if plan.purgeWithheld {
            log.notice("Compiled model cache left in place: another Daisy is running")
        }
        guard let compiledCache else { return plan }
        if plan.purgeCompiledCache {
            if let aside = CompiledModelCache.moveAside(compiledCache) {
                if plan.firstLaunchPurge {
                    log.notice("First launch with the guard after a crashed run: compiled model cache moved aside (\(aside.lastPathComponent, privacy: .public))")
                } else {
                    log.notice("Compiled model cache moved aside to be deleted: \(aside.lastPathComponent, privacy: .public)")
                }
            } else {
                log.notice("No compiled model cache to move aside, or it couldn't be moved")
            }
        }
        // Every launch, not only this one's purge: a launch that died before
        // its delete finished leaves the moved-aside copy behind.
        let logger = log
        cleanup = Task.detached(priority: .utility) {
            let removed = CompiledModelCache.removeMovedAside(beside: compiledCache)
            if removed > 0 { logger.notice("Deleted \(removed, privacy: .public) moved-aside compiled model cache(s)") }
        }
        return plan
    }

    // MARK: - Around a load

    /// `load`, with this engine's marker on disk for as long as it runs.
    func run<T>(_ engine: ModelLoadEngine, _ load: () async throws -> T) async rethrows -> T {
        begin(engine)
        do {
            let value = try await load()
            end(engine, succeeded: true)
            return value
        } catch {
            end(engine, succeeded: false)
            throw error
        }
    }

    private func begin(_ engine: ModelLoadEngine) {
        guard store.isActive else { return }
        var entry = inFlight[engine] ?? (count: 0, succeeded: false)
        entry.count += 1
        inFlight[engine] = entry
        guard entry.count == 1 else { return }
        let record = Policy.whileLoading(store.read(engine), flight: .init(
            pid: pid, startedAt: Date(), build: build, mayDownload: downloadWindowIsOpen(),
            crashHandlerInstalled: crashHandlerInstalled()))
        if !store.write(record, for: engine) { noteUnwritable() }
    }

    private func end(_ engine: ModelLoadEngine, succeeded: Bool) {
        guard store.isActive, var entry = inFlight[engine] else { return }
        entry.count -= 1
        entry.succeeded = entry.succeeded || succeeded
        guard entry.count <= 0 else {
            inFlight[engine] = entry
            return
        }
        inFlight[engine] = nil
        let next = Policy.afterLoad(store.read(engine), succeeded: entry.succeeded, pid: pid)
        if !store.put(next, for: engine) { noteUnwritable() }
    }

    private func noteUnwritable() {
        guard !saidUnwritable else { return }
        saidUnwritable = true
        log.error("Can't write the model-load markers in \(self.store.directory?.path ?? "-", privacy: .public) — loads go on without them")
    }

    // MARK: - Holds

    func heldMessage(for engine: ModelLoadEngine) -> String? {
        held.contains(engine) ? Self.heldMessage(naming: engine) : nil
    }

    /// What a held engine shows in place of loading.
    nonisolated static func heldMessage(naming engine: ModelLoadEngine) -> String {
        String(localized: "Daisy closed twice in a row while loading \(engine.nameAfterLoading). It won’t load it on its own any more. Press Download and check to try again")
    }

    /// One line per held model, in `ModelLoadEngine`'s order (the meeting
    /// model and a job's model read the same and give one line).
    var heldMessages: [String] {
        var lines: [String] = []
        for engine in ModelLoadEngine.allCases where held.contains(engine) {
            let line = Self.heldMessage(naming: engine)
            if !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    func refuseIfHeld(_ engine: ModelLoadEngine) throws {
        if let message = heldMessage(for: engine) { throw ModelLoadHeldError(message: message) }
    }

    /// The person asked for these engines' models. Kept on disk as one
    /// strike short of a hold (`Policy.afterLift`); the engines drop the
    /// held text they were showing (`afterLift`), so the card and the rows
    /// stop saying it and the next ask loads.
    func liftHolds(_ engines: Set<ModelLoadEngine> = Set(ModelLoadEngine.allCases), now: Date = Date()) {
        let lifting = held.intersection(engines)
        guard !lifting.isEmpty else { return }
        for engine in ModelLoadEngine.allCases where lifting.contains(engine) {
            if let record = store.read(engine), !store.put(Policy.afterLift(record, now: now), for: engine) {
                noteUnwritable()
            }
            log.notice("Hold on \(engine.rawValue, privacy: .public) lifted at the person's request")
        }
        held.subtract(lifting)
        afterLift(lifting)
    }

    /// `liftHolds` for a button that goes on to load the models. Parakeet,
    /// speech detection and the diarizer have no «download again» of their
    /// own, so their files are first checked against the pinned manifest
    /// and the wrong ones fetched (`checkFilesAgainstManifest`) — before
    /// the lift, so nothing loads them half-checked. A check that can't run
    /// (offline, no room) doesn't keep the hold. A second press while the
    /// check is still running waits for it and starts no second one.
    /// `now`: the lift's date, for tests; the moment of the lift otherwise.
    func liftHoldsBeforeLoading(_ engines: Set<ModelLoadEngine> = Set(ModelLoadEngine.allCases),
                                now: Date? = nil) async {
        while let running = liftTask { await running.value }
        let lifting = held.intersection(engines)
        guard !lifting.isEmpty else { return }
        let task = Task { @MainActor in
            for engine in ModelLoadEngine.allCases where lifting.contains(engine) {
                await self.checkFiles(engine)
            }
            self.liftHolds(lifting, now: now ?? Date())
            // Here and not after the wait below: whoever waited on this
            // task must find it gone when they come back.
            self.liftTask = nil
        }
        liftTask = task
        await task.value
    }

    /// The default `checkFiles`: the engine's files against the bundled
    /// manifest, the missing or wrong ones fetched again. Whisper has
    /// «Download speech model again» for that; Nemotron has no manifest.
    static func checkFilesAgainstManifest(_ engine: ModelLoadEngine) async {
        #if canImport(FluidAudio)
        let set: MacModelHosting.ModelSet
        switch engine {
        case .parakeet: set = .parakeetV3
        case .speechDetection: set = .sileroVAD
        case .diarizer: set = .diarizer
        case .whisper, .whisperJob, .nemotron: return
        }
        _ = try? await MacModelHosting.repairAfterFailedLoad(set)
        #endif
    }

    /// The default `afterLift`: each engine that was showing its held
    /// message goes back to not loaded.
    static func clearHeldFailures(_ engines: Set<ModelLoadEngine>) {
        for engine in engines {
            let message = heldMessage(naming: engine)
            switch engine {
            case .whisper: WhisperEngine.shared.clearHeldFailure(message)
            case .parakeet: ParakeetEngine.shared.clearHeldFailure(message)
            case .nemotron: NemotronLiveEngine.shared.clearHeldFailure(message)
            case .diarizer: DiarizationEngine.shared.clearHeldFailure(message)
            // Neither keeps a state of its own to clear.
            case .whisperJob, .speechDetection: break
            }
        }
    }

    // MARK: - Quit

    /// A normal quit in the middle of a load is not a death: all of this
    /// process's markers go (`DaisyAppDelegate.applicationWillTerminate`).
    func clearOwnMarkersAtTermination() {
        guard store.isActive else { return }
        for (engine, record) in store.readAll() {
            let next = Policy.atTermination(record, pid: pid)
            if next != record { store.put(next, for: engine) }
        }
    }

    // MARK: - Telling the person

    /// «Daisy closed twice while loading the speech model and speaker
    /// separation»: every model in `engines`, each named once.
    nonisolated static func launchNoticeText(
        for engines: [ModelLoadEngine],
        locale: Locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    ) -> String {
        var names: [String] = []
        for engine in engines where !names.contains(engine.nameAfterLoading) {
            names.append(engine.nameAfterLoading)
        }
        let formatter = ListFormatter()
        formatter.locale = locale
        let list = formatter.string(from: names) ?? names.joined(separator: ", ")
        return String(localized: "Daisy closed twice while loading \(list)")
    }

    /// The launch on which engines became held says so once, where the
    /// person is: a toast in the window and the widget's bubble (or a
    /// notification), with the way to the card that lifts it. Not a modal:
    /// the crash-report question may be up at the same time.
    func presentLaunchNotice() {
        guard let first = announced.first else { return }
        let message = Self.launchNoticeText(for: announced)
        let open: @MainActor () -> Void = {
            switch first {
            case .parakeet, .nemotron:
                AppNavigation.shared.openInSettings(.dictation, row: .dictationEngine)
            case .whisper, .whisperJob, .speechDetection, .diarizer:
                AppNavigation.shared.openInSettings(.meetings, row: .meetingModel)
            }
        }
        ToastCenter.shared.showAction(message, actionLabel: String(localized: "Set up"),
                                      style: .warning, duration: .seconds(15), perform: open)
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(text: message, actionTitle: String(localized: "Set up"), action: open),
            notificationTitle: String(localized: "Prepare Daisy"))
    }

    // MARK: - Whose marker

    nonisolated static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// A Daisy with this bundle id is running besides this process — the
    /// old instance of a language relaunch, a second copy. The compiled
    /// cache is shared by bundle id, so it isn't moved while one is up.
    nonisolated static func anotherDaisyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return anotherInstance(amongPIDs: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
            // The list can still carry the run that has just crashed; a
            // process that is gone must not keep the cache from being moved.
            .filter(processExists),
                               own: ProcessInfo.processInfo.processIdentifier)
    }

    nonisolated static func anotherInstance(amongPIDs pids: [Int32], own: Int32) -> Bool {
        pids.contains { $0 != own && $0 > 0 }
    }

    /// Whether `pid` is a running Daisy: the process exists and is this
    /// app by bundle id. After a restart of the Mac a marker's pid can
    /// belong to anything.
    nonisolated static func isAnotherRunningDaisy(_ pid: Int32) -> Bool {
        guard processExists(pid),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == bundleID
    }
}
