//
//  ModelLoadGuardTests.swift
//  DaisyTests
//
//  Sentry DAISY-MAC-4 (12.11): Daisy 1.0.8.49 aborted inside Core ML twice
//  in 28 minutes on one Mac, while Whisper's load read a compiled package
//  and another thread was in a FluidAudio model load. An abort can't be
//  caught, so a marker on disk says a load was under way. The launch that
//  finds one left by a dead process moves the compiled cache aside and
//  skips the preload; when there is evidence that run crashed, the engine
//  gets a strike, and at two it waits for the person.
//
//  Everything here runs on temporary folders and made-up process ids; the
//  app's own guard is inert in the test host.
//

import Foundation
import Sentry
import Testing
@testable import Daisy

@Suite("Model load guard: decisions")
struct ModelLoadGuardPolicyTests {
    typealias Policy = ModelLoadGuardPolicy
    typealias Record = ModelLoadGuardPolicy.Record

    private let build = "1.0.8.50 (167)"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    /// A marker of a run that had Sentry's crash handler in it, unless
    /// `handler` says otherwise.
    private func flight(_ pid: Int32, build: String? = nil, mayDownload: Bool = false,
                        handler: Bool = true) -> Policy.InFlight {
        .init(pid: pid, startedAt: now.addingTimeInterval(-60), build: build ?? self.build,
              mayDownload: mayDownload, crashHandlerInstalled: handler)
    }

    private func struck(_ strikes: Int, daysAgo: Double = 0, build: String? = nil,
                        loading: Policy.InFlight? = nil) -> Record {
        Record(strikes: strikes, strikesBuild: build ?? self.build,
               lastStrikeAt: now.addingTimeInterval(-daysAgo * day), loading: loading)
    }

    /// `crashed`: what Sentry's record says of the last run.
    private func atLaunch(_ found: [ModelLoadEngine: Record], alive: Set<Int32> = [], crashed: Bool,
                          anotherInstance: Bool = false) -> Policy.LaunchPlan {
        Policy.atLaunch(found, isAlive: { alive.contains($0) }, lastRun: crashed ? .crashed : .didNotCrash,
                        build: build, now: now, anotherInstanceRunning: anotherInstance)
    }

    @Test("No markers: nothing to do")
    func noRecords() {
        #expect(atLaunch([:], crashed: true) == Policy.LaunchPlan())
        #expect(atLaunch([:], crashed: false) == Policy.LaunchPlan())
    }

    @Test("A dead marker and a crash: strike one, cache purged, preload skipped, nothing held")
    func firstCrash() {
        let plan = atLaunch([.whisper: Record(loading: flight(41))], crashed: true)
        #expect(plan.records[.whisper] == struck(1))
        #expect(plan.died == [.whisper])
        #expect(plan.struck == [.whisper])
        #expect(plan.purgeCompiledCache)
        #expect(plan.skipPreload)
        #expect(plan.held.isEmpty)
        #expect(plan.announce.isEmpty)
    }

    @Test("Every answer about the last run, for a marker with the crash handler in its run and for one without")
    func evidenceMatrix() {
        typealias LastRun = CrashReports.LastRun
        // (what Sentry reports now, the handler was in the marker's run) → struck
        let cases: [(LastRun, Bool, Bool)] = [
            (.crashed, true, true),
            (.didNotCrash, true, false),   // the one case on record as not a crash
            (.unknown, true, true),
            // No handler in that run: whatever is reported is about another run.
            (.crashed, false, true),
            (.didNotCrash, false, true),
            (.unknown, false, true),
        ]
        for (reported, handler, struckExpected) in cases {
            let marker = flight(41, handler: handler)
            #expect(Policy.evidence(for: marker, lastRun: reported) == (handler ? reported : .unknown))
            let plan = Policy.atLaunch([.whisper: Record(loading: marker)], isAlive: { _ in false },
                                       lastRun: reported, build: build, now: now)
            #expect(plan.struck == (struckExpected ? [.whisper] : []), "\(reported), handler \(handler)")
            #expect(plan.records[.whisper] == (struckExpected ? struck(1) : Record()), "\(reported), handler \(handler)")
            // Whatever the evidence: the cache is purged and the preload skipped.
            #expect(plan.died == [.whisper])
            #expect(plan.purgeCompiledCache && plan.skipPreload)
            #expect(plan.held.isEmpty)
        }
        // Two deaths nobody recorded — crash reports off — hold the engine, as two crashes do.
        let second = Policy.atLaunch([.whisper: struck(1, daysAgo: 1, loading: flight(41, handler: false))],
                                     isAlive: { _ in false }, lastRun: .unknown, build: build, now: now)
        #expect(second.held == [.whisper])
        #expect(second.announce == [.whisper])
    }

    @Test("Sentry's status maps to three answers, and to none while it isn't started")
    func lastRunMapping() {
        #expect(CrashReports.lastRun(started: true, status: .didCrash) == .crashed)
        #expect(CrashReports.lastRun(started: true, status: .didNotCrash) == .didNotCrash)
        #expect(CrashReports.lastRun(started: true, status: .unknown) == .unknown)
        for status in [SentryLastRunStatus.didCrash, .didNotCrash, .unknown] {
            #expect(CrashReports.lastRun(started: false, status: status) == .unknown)
        }
    }

    @Test("Another Daisy running: the compiled cache is not moved from under it; the preload is still skipped")
    func anotherInstanceWithholdsThePurge() {
        let plan = atLaunch([.whisper: Record(loading: flight(41))], crashed: true, anotherInstance: true)
        #expect(plan.died == [.whisper])
        #expect(plan.struck == [.whisper])
        #expect(!plan.purgeCompiledCache)
        #expect(plan.purgeWithheld)
        #expect(plan.skipPreload)
        // Nothing died: nothing to withhold.
        let calm = atLaunch([.whisper: struck(1)], crashed: false, anotherInstance: true)
        #expect(!calm.purgeCompiledCache && !calm.purgeWithheld && !calm.skipPreload)
        // A download-window marker never asked for a purge.
        let download = atLaunch([.nemotron: Record(loading: flight(41, mayDownload: true))], crashed: true, anotherInstance: true)
        #expect(!download.purgeCompiledCache && !download.purgeWithheld && download.skipPreload)

        #expect(ModelLoadGuard.anotherInstance(amongPIDs: [500, 612], own: 500))
        #expect(!ModelLoadGuard.anotherInstance(amongPIDs: [500], own: 500))
        #expect(!ModelLoadGuard.anotherInstance(amongPIDs: [], own: 500))
    }

    @Test("The first launch with the guard after a crashed run purges the cache — and nothing else")
    func firstLaunchWithGuard() {
        func first(_ lastRun: CrashReports.LastRun, another: Bool = false, first: Bool = true) -> Policy.LaunchPlan {
            Policy.atLaunch([:], isAlive: { _ in false }, lastRun: lastRun, build: build, now: now,
                            anotherInstanceRunning: another, firstLaunchWithGuard: first)
        }
        // 1.0.8.49 died and left no marker: the fixed build's first launch.
        let healed = first(.crashed)
        #expect(healed.purgeCompiledCache)
        #expect(healed.firstLaunchPurge)
        #expect(!healed.skipPreload)
        #expect(healed.struck.isEmpty && healed.died.isEmpty && healed.held.isEmpty && healed.records.isEmpty)
        // No crash on record, or no record: nothing.
        #expect(first(.didNotCrash) == Policy.LaunchPlan())
        #expect(first(.unknown) == Policy.LaunchPlan())
        // Any later launch: a crashed run with no marker is not a load's.
        #expect(first(.crashed, first: false) == Policy.LaunchPlan())
        // Another Daisy is up: its models came from that folder.
        let withheld = first(.crashed, another: true)
        #expect(!withheld.purgeCompiledCache && !withheld.firstLaunchPurge)
        #expect(withheld.purgeWithheld)
        #expect(!withheld.skipPreload)
    }

    @Test("A dead marker on record as not a crash — a Force Quit, a power cut with the handler watching: purge and skip, no strike")
    func deathWithoutCrashEvidence() {
        let plan = atLaunch([.whisper: Record(loading: flight(41))], crashed: false)
        #expect(plan.records[.whisper] == Record())
        #expect(plan.records[.whisper]?.isEmpty == true)
        #expect(plan.died == [.whisper])
        #expect(plan.struck.isEmpty)
        #expect(plan.purgeCompiledCache)
        #expect(plan.skipPreload)
        #expect(plan.held.isEmpty)
    }

    @Test("Any number of Force Quits during a load never holds an engine")
    func forceQuitsNeverHold() {
        var record = Record()
        for _ in 0..<5 {
            record = Policy.whileLoading(record, flight: flight(41))
            let plan = atLaunch([.whisper: record], crashed: false)
            #expect(plan.held.isEmpty)
            #expect(plan.purgeCompiledCache && plan.skipPreload)
            record = plan.records[.whisper] ?? Record()
        }
        #expect(record == Record())
        // …nor does one take a crash's strike further.
        let plan = atLaunch([.whisper: struck(1, loading: flight(41))], crashed: false)
        #expect(plan.records[.whisper] == struck(1))
        #expect(plan.held.isEmpty)
    }

    @Test("A marker whose process is another running Daisy is left as it is")
    func aliveMarkerIsIgnored() {
        let record = Record(loading: flight(41))
        let plan = atLaunch([.whisper: record], alive: [41], crashed: true)
        #expect(plan.records[.whisper] == record)
        #expect(plan.died.isEmpty)
        #expect(!plan.purgeCompiledCache && !plan.skipPreload && plan.held.isEmpty)
    }

    @Test("The second crash in a row holds the engine and says so")
    func secondCrash() {
        let plan = atLaunch([.parakeet: struck(1, daysAgo: 1, loading: flight(41))], crashed: true)
        #expect(plan.records[.parakeet] == struck(2))
        #expect(plan.held == [.parakeet])
        #expect(plan.announce == [.parakeet])
        #expect(plan.purgeCompiledCache && plan.skipPreload)
    }

    @Test("Two strikes and no new death: still held, said nothing, nothing purged or skipped")
    func heldFromBefore() {
        let plan = atLaunch([.parakeet: struck(2, daysAgo: 1)], crashed: false)
        #expect(plan.held == [.parakeet])
        #expect(plan.announce.isEmpty)
        #expect(plan.died.isEmpty)
        #expect(!plan.purgeCompiledCache && !plan.skipPreload)
        // A crash somewhere else, with no marker of this engine's, changes nothing.
        #expect(atLaunch([.parakeet: struck(1, daysAgo: 1)], crashed: true).records[.parakeet] == struck(1, daysAgo: 1))
    }

    @Test("Two engines dead at once in a crash: both struck, one purge")
    func twoDeaths() {
        let plan = atLaunch([.whisper: Record(loading: flight(41)),
                             .parakeet: Record(loading: flight(41))], crashed: true)
        #expect(plan.died == [.whisper, .parakeet])
        #expect(plan.struck == [.whisper, .parakeet])
        #expect(plan.records[.whisper]?.strikes == 1)
        #expect(plan.records[.parakeet]?.strikes == 1)
        #expect(plan.purgeCompiledCache)
        #expect(plan.held.isEmpty)
    }

    @Test("Engines count their own strikes")
    func independentCounts() {
        let plan = atLaunch([.whisper: struck(1, daysAgo: 1),
                             .parakeet: Record(loading: flight(41))], crashed: true)
        #expect(plan.records[.whisper] == struck(1, daysAgo: 1))
        #expect(plan.records[.parakeet] == struck(1))
        #expect(plan.died == [.parakeet])
        #expect(plan.held.isEmpty)
    }

    @Test("A marker written inside a download window: the preload is skipped, nothing is struck or purged")
    func deathWhileMaybeDownloading() {
        for crashed in [true, false] {
            let plan = atLaunch([.nemotron: struck(1, daysAgo: 1, loading: flight(41, mayDownload: true))], crashed: crashed)
            #expect(plan.died == [.nemotron])
            #expect(plan.skipPreload)
            #expect(!plan.purgeCompiledCache)
            #expect(plan.struck.isEmpty)
            #expect(plan.records[.nemotron] == struck(1, daysAgo: 1))
            #expect(plan.held.isEmpty)
        }
        // Beside a real load's marker the purge still happens.
        let both = atLaunch([.nemotron: Record(loading: flight(41, mayDownload: true)),
                             .whisper: Record(loading: flight(41))], crashed: true)
        #expect(both.purgeCompiledCache)
        #expect(both.struck == [.whisper])
    }

    @Test("Strikes and a hold don't outlive the build that recorded them")
    func strikesExpireWithTheBuild() {
        let older = "1.0.8.49 (166)"
        // A hold set by the last build is gone in this one…
        let plan = atLaunch([.whisper: struck(2, daysAgo: 1, build: older)], crashed: false)
        #expect(plan.held.isEmpty)
        #expect(plan.records[.whisper] == Record())
        // …and a strike of its doesn't make this build's first crash the second.
        let next = atLaunch([.whisper: struck(1, daysAgo: 1, build: older, loading: flight(41))], crashed: true)
        #expect(next.records[.whisper] == struck(1))
        #expect(next.held.isEmpty)
        // The last build's death, found by this build: purge and skip, no strike.
        let foreign = atLaunch([.whisper: Record(loading: flight(41, build: older))], crashed: true)
        #expect(foreign.died == [.whisper])
        #expect(foreign.struck.isEmpty)
        #expect(foreign.purgeCompiledCache && foreign.skipPreload)
        #expect(foreign.records[.whisper] == Record())
        // A record with strikes and no build at all doesn't count either.
        #expect(Policy.unexpired(Record(strikes: 2), build: build, now: now) == Record())
    }

    @Test("A strike older than seven days is dropped: two in a row is not one in March and one in November")
    func strikesExpireWithAge() {
        #expect(Policy.unexpired(struck(1, daysAgo: 6.9), build: build, now: now) == struck(1, daysAgo: 6.9))
        #expect(Policy.unexpired(struck(1, daysAgo: 7.1), build: build, now: now) == Record())
        // The old one is gone before the new one is counted.
        let plan = atLaunch([.whisper: struck(1, daysAgo: 240, loading: flight(41))], crashed: true)
        #expect(plan.records[.whisper] == struck(1))
        #expect(plan.held.isEmpty)
        // The marker stays through the expiry.
        let loading = struck(1, daysAgo: 8, loading: flight(41))
        #expect(Policy.unexpired(loading, build: build, now: now) == Record(loading: flight(41)))
        // A hold doesn't age: it ends with the person's ask or another build.
        #expect(Policy.unexpired(struck(2, daysAgo: 30), build: build, now: now) == struck(2, daysAgo: 30))
        #expect(atLaunch([.whisper: struck(2, daysAgo: 30)], crashed: false).held == [.whisper])
    }

    @Test("A load that worked clears the strikes; one that threw keeps them")
    func afterLoad() {
        let loading = struck(1, loading: flight(7))
        #expect(Policy.afterLoad(loading, succeeded: true, pid: 7) == nil)
        #expect(Policy.afterLoad(loading, succeeded: false, pid: 7) == struck(1))
        // Nothing to remember: no file.
        #expect(Policy.afterLoad(Record(loading: flight(7)), succeeded: false, pid: 7) == nil)
        #expect(Policy.afterLoad(nil, succeeded: false, pid: 7) == nil)
    }

    @Test("A marker another Daisy wrote meanwhile stays that Daisy's")
    func afterLoadKeepsAnothersMarker() {
        let theirs = struck(1, loading: flight(99))
        #expect(Policy.afterLoad(theirs, succeeded: false, pid: 7) == theirs)
        #expect(Policy.afterLoad(theirs, succeeded: true, pid: 7) == Record(loading: flight(99)))
    }

    @Test("Strikes carry into the next load's marker")
    func whileLoading() {
        #expect(Policy.whileLoading(struck(1), flight: flight(7)) == struck(1, loading: flight(7)))
        #expect(Policy.whileLoading(nil, flight: flight(7)) == Record(loading: flight(7)))
    }

    @Test("A lifted hold is one strike short of the next one, dated the day of the lift")
    func afterLift() throws {
        #expect(Policy.afterLift(struck(2), now: now) == struck(1))
        #expect(Policy.afterLift(struck(5), now: now) == struck(1))
        #expect(Policy.afterLift(Record(), now: now) == nil)
        // …so the launch after it loads, and the next crash holds again.
        let lifted = try #require(Policy.afterLift(struck(2), now: now))
        #expect(atLaunch([.whisper: lifted], crashed: false).held.isEmpty)
        let again = Policy.whileLoading(lifted, flight: flight(41))
        #expect(atLaunch([.whisper: again], crashed: true).held == [.whisper])
        #expect(atLaunch([.whisper: again], crashed: false).held.isEmpty)
    }

    @Test("A hold set ten days ago and lifted today: the next crash holds it again")
    func agedHoldLiftedThenCrash() throws {
        let aged = struck(2, daysAgo: 10)
        #expect(atLaunch([.whisper: aged], crashed: false).held == [.whisper])
        let lifted = try #require(Policy.afterLift(aged, now: now))
        #expect(lifted == struck(1))
        // With the hold's own date the strike would be eight days past its week here.
        let nextLaunch = now.addingTimeInterval(day)
        let again = Policy.whileLoading(lifted, flight: flight(41))
        let plan = Policy.atLaunch([.whisper: again], isAlive: { _ in false }, lastRun: .crashed,
                                   build: build, now: nextLaunch)
        #expect(plan.records[.whisper]?.strikes == 2)
        #expect(plan.held == [.whisper])
        #expect(plan.announce == [.whisper])
    }

    @Test("A quit clears every marker of this process, however long the load has run, and no one else's")
    func termination() {
        #expect(Policy.atTermination(Record(loading: flight(7)), pid: 7) == nil)
        #expect(Policy.atTermination(struck(1, loading: flight(7)), pid: 7) == struck(1))
        // The lid was closed for an hour in the middle of the load; then a quit.
        var old = flight(7)
        old.startedAt = now.addingTimeInterval(-3 * 60 * 60)
        #expect(Policy.atTermination(Record(loading: old), pid: 7) == nil)
        var downloading = flight(7, mayDownload: true)
        downloading.startedAt = now.addingTimeInterval(-60 * 60)
        #expect(Policy.atTermination(Record(loading: downloading), pid: 7) == nil)

        let theirs = Record(loading: flight(99))
        #expect(Policy.atTermination(theirs, pid: 7) == theirs)
        let idle = struck(2)
        #expect(Policy.atTermination(idle, pid: 7) == idle)
    }

    @Test("The compiled cache is exactly one child of the app's Caches folder — and nothing without a bundle id")
    func compiledCacheURL() {
        let caches = URL(fileURLWithPath: "/Users/x/Library/Caches")
        #expect(Policy.compiledCacheURL(cachesRoot: caches, bundleID: "app.essazanov.Daisy")?.path
                == "/Users/x/Library/Caches/app.essazanov.Daisy/com.apple.e5rt.e5bundlecache")
        // Without one the path would be ~/Library/Caches/com.apple.e5rt.e5bundlecache,
        // which exists and is not Daisy's.
        for missing in [nil, "", "  ", "\n", ".", "..", "a/b"] as [String?] {
            #expect(Policy.compiledCacheURL(cachesRoot: caches, bundleID: missing) == nil, "bundle id \(missing ?? "nil")")
        }
    }

    @Test("Markers: Application Support in Release, nowhere in tests, in Debug only where the variable says")
    func markerDirectory() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
        let named = [Policy.directoryVariable: "/tmp/guard-check"]
        #expect(Policy.markerDirectory(isTestHost: false, isDebugBuild: false, environment: [:], applicationSupport: support)?.path
                == "/Users/x/Library/Application Support/Daisy/model-load-guard")
        // Release ignores the variable.
        #expect(Policy.markerDirectory(isTestHost: false, isDebugBuild: false, environment: named, applicationSupport: support)?.path
                == "/Users/x/Library/Application Support/Daisy/model-load-guard")
        #expect(Policy.markerDirectory(isTestHost: false, isDebugBuild: true, environment: [:], applicationSupport: support) == nil)
        #expect(Policy.markerDirectory(isTestHost: false, isDebugBuild: true, environment: [Policy.directoryVariable: ""], applicationSupport: support) == nil)
        #expect(Policy.markerDirectory(isTestHost: false, isDebugBuild: true, environment: named, applicationSupport: support)?.path
                == "/tmp/guard-check")
        #expect(Policy.markerDirectory(isTestHost: true, isDebugBuild: false, environment: named, applicationSupport: support) == nil)
        #expect(Policy.markerDirectory(isTestHost: true, isDebugBuild: true, environment: named, applicationSupport: support) == nil)
        #expect(Policy.markerDirectory(isTestHost: false, isDebugBuild: false, environment: [:], applicationSupport: nil) == nil)
    }

    @Test("In the test host the app's own guard does nothing and has no crash evidence to read")
    @MainActor
    func sharedGuardIsInertHere() {
        #expect(ModelLoadGuard.shared.checkAtLaunch() == nil)
        #expect(ModelLoadGuard.shared.held.isEmpty)
        #expect(!ModelLoadGuard.shared.skipsLaunchPreload)
        // Sentry isn't started by the app here: no handler, no answer.
        #expect(!CrashReports.handlerInstalled)
        #expect(CrashReports.lastRun == .unknown)
    }
}

@MainActor
@Suite("Model load guard: markers on disk")
struct ModelLoadMarkerStoreTests {
    typealias Policy = ModelLoadGuardPolicy
    typealias Record = ModelLoadGuardPolicy.Record

    private let fm = FileManager.default
    private let me: Int32 = 500
    private let build = "test (1)"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("ModelLoadGuardTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func flight(_ pid: Int32, build: String? = nil, mayDownload: Bool = false,
                        handler: Bool = true) -> Policy.InFlight {
        .init(pid: pid, startedAt: now.addingTimeInterval(-60), build: build ?? self.build,
              mayDownload: mayDownload, crashHandlerInstalled: handler)
    }

    private func struck(_ strikes: Int, at date: Date? = nil) -> Record {
        Record(strikes: strikes, strikesBuild: build, lastStrikeAt: date ?? now, loading: nil)
    }

    /// A guard as one launch of Daisy would have it: process `pid`, with
    /// `alive` the other Daisys still running and `crashed` what the crash
    /// reporter says of the run before.
    private func launch(markers: URL?, cache: URL? = nil, pid: Int32? = nil, alive: Set<Int32> = [],
                        crashed: Bool = true, build: String? = nil, handler: Bool = true,
                        anotherInstance: Bool = false) -> ModelLoadGuard {
        ModelLoadGuard(store: ModelLoadMarkerStore(directory: markers), compiledCache: cache,
                       pid: pid ?? me, build: build ?? self.build,
                       isAlive: { alive.contains($0) }, lastRun: { crashed ? .crashed : .didNotCrash },
                       crashHandlerInstalled: { handler }, anotherInstanceRunning: { anotherInstance },
                       downloadWindowIsOpen: { false }, checkFiles: { _ in }, afterLift: { _ in })
    }

    /// A compiled cache with something in it, beside the things that share
    /// the app's Caches folder.
    private func makeCaches(in root: URL) throws -> (cache: URL, siblings: [URL]) {
        let app = root.appendingPathComponent("Caches/app.essazanov.Daisy", isDirectory: true)
        let cache = try #require(Policy.compiledCacheURL(cachesRoot: root.appendingPathComponent("Caches"),
                                                         bundleID: "app.essazanov.Daisy"))
        try fm.createDirectory(at: cache.appendingPathComponent("26A428/ABCDEF"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cache.appendingPathComponent("26A428/ABCDEF/model.bundle"))
        let sparkle = app.appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
        try fm.createDirectory(at: sparkle, withIntermediateDirectories: true)
        try Data([4]).write(to: sparkle.appendingPathComponent("update.dmg"))
        let db = app.appendingPathComponent("Cache.db")
        try Data([5]).write(to: db)
        return (cache, [sparkle.appendingPathComponent("update.dmg"), db])
    }

    private func names(in folder: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: The store

    @Test("A marker written by one process is read by the next")
    func survivesTheProcess() throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        var record = struck(1)
        record.loading = flight(41)
        #expect(ModelLoadMarkerStore(directory: dir).write(record, for: .parakeet))
        let next = ModelLoadMarkerStore(directory: dir)
        #expect(next.read(.parakeet) == record)
        #expect(next.readAll() == [.parakeet: record])
        #expect(names(in: dir) == ["parakeet.json"])
        #expect(next.remove(.parakeet))
        #expect(next.readAll().isEmpty)
        #expect(next.remove(.parakeet))
        // A record with nothing in it is no file.
        #expect(next.put(Record(), for: .parakeet))
        #expect(names(in: dir).isEmpty)
    }

    @Test("A file that isn't a record reads as no record, and is written over")
    func corruptFile() throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("whisper.json"))
        try Data().write(to: dir.appendingPathComponent("diarizer.json"))
        let store = ModelLoadMarkerStore(directory: dir)
        #expect(store.read(.whisper) == nil)
        #expect(store.readAll().isEmpty)
        #expect(store.write(struck(1), for: .whisper))
        #expect(store.read(.whisper) == struck(1))
    }

    @Test("Without a directory every call is a no-op")
    func inertStore() {
        let store = ModelLoadMarkerStore(directory: nil)
        #expect(!store.isActive)
        #expect(store.write(struck(1), for: .whisper))
        #expect(store.read(.whisper) == nil)
        #expect(store.readAll().isEmpty)
        #expect(store.remove(.whisper))
    }

    // MARK: Around a load

    @Test("The marker is on disk, with this process's id and build, exactly while the load runs")
    func markerWhileLoading() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let loadGuard = launch(markers: dir)
        let store = ModelLoadMarkerStore(directory: dir)
        #expect(store.read(.whisper) == nil)
        let value = try await loadGuard.run(.whisper) { () async throws -> Int in
            let marker = store.read(.whisper)
            #expect(marker?.loading?.pid == 500)
            #expect(marker?.loading?.build == "test (1)")
            #expect(marker?.loading?.mayDownload == false)
            #expect(marker?.loading?.crashHandlerInstalled == true)
            #expect(marker?.strikes == 0)
            return 7
        }
        #expect(value == 7)
        #expect(store.read(.whisper) == nil)
        #expect(names(in: dir).isEmpty)

        // Started inside a FluidAudio download window: marked as such.
        // …and a run without Sentry's handler (crash reports off) says so.
        let inWindow = ModelLoadGuard(store: store, compiledCache: nil, pid: 500, build: build,
                                      isAlive: { _ in false }, lastRun: { .unknown },
                                      crashHandlerInstalled: { false }, anotherInstanceRunning: { false },
                                      downloadWindowIsOpen: { true }, checkFiles: { _ in }, afterLift: { _ in })
        await inWindow.run(.nemotron) {
            #expect(store.read(.nemotron)?.loading?.mayDownload == true)
            #expect(store.read(.nemotron)?.loading?.crashHandlerInstalled == false)
        }
        #expect(store.read(.nemotron) == nil)
    }

    @Test("A marker from before a field existed reads it as false")
    func olderMarkerDecodes() throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        try Data(#"{"strikes":0,"loading":{"pid":41,"startedAt":1800000000,"build":"test (1)"}}"#.utf8)
            .write(to: dir.appendingPathComponent("whisper.json"))
        let flight = try #require(ModelLoadMarkerStore(directory: dir).read(.whisper)?.loading)
        #expect(flight.pid == 41)
        #expect(flight.build == "test (1)")
        #expect(!flight.mayDownload)
        #expect(!flight.crashHandlerInstalled)
    }

    @Test("A load that throws keeps the strikes and drops the marker; one that works clears them")
    func throwKeepsStrikes() async throws {
        struct Boom: Error {}
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let store = ModelLoadMarkerStore(directory: dir)
        store.write(struck(1), for: .parakeet)
        let loadGuard = launch(markers: dir)
        await #expect(throws: Boom.self) {
            try await loadGuard.run(.parakeet) {
                #expect(store.read(.parakeet)?.strikes == 1)
                #expect(store.read(.parakeet)?.loading?.pid == 500)
                throw Boom()
            }
        }
        #expect(store.read(.parakeet) == struck(1))
        await loadGuard.run(.parakeet) {}
        #expect(store.read(.parakeet) == nil)
    }

    @Test("Two loads of one engine at once: the marker stays until the last ends")
    func overlappingLoads() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let store = ModelLoadMarkerStore(directory: dir)
        let loadGuard = launch(markers: dir)
        let first = Hold(), second = Hold()
        let a = Task { @MainActor in await loadGuard.run(.parakeet) { await first.wait() } }
        let b = Task { @MainActor in await loadGuard.run(.parakeet) { await second.wait() } }
        #expect(await eventually { first.entered && second.entered })
        #expect(store.read(.parakeet)?.loading?.pid == 500)
        first.open()
        await a.value
        #expect(store.read(.parakeet)?.loading?.pid == 500)
        second.open()
        await b.value
        #expect(store.read(.parakeet) == nil)
    }

    @Test("Markers that can't be written never stop a load")
    func unwritableOrMissingDirectory() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        // A file where the directory should be: nothing can be created in it.
        let blocked = root.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: blocked)
        let unwritable = launch(markers: blocked.appendingPathComponent("model-load-guard"), crashed: false)
        #expect(await unwritable.run(.whisper) { 1 } == 1)
        #expect(await unwritable.run(.whisper) { 2 } == 2)
        #expect(unwritable.checkAtLaunch() == Policy.LaunchPlan())

        let inert = launch(markers: nil)
        #expect(await inert.run(.whisper) { 3 } == 3)
        #expect(inert.checkAtLaunch() == nil)
        inert.clearOwnMarkersAtTermination()
        #expect(inert.held.isEmpty)
    }

    // MARK: Quit

    @Test("A quit clears all of this process's markers and only those")
    func termination() throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let store = ModelLoadMarkerStore(directory: dir)
        var hours = flight(me)
        hours.startedAt = now.addingTimeInterval(-5 * 60 * 60)
        var withStrike = struck(1)
        withStrike.loading = flight(me)
        store.write(Record(loading: flight(me)), for: .whisper)
        store.write(withStrike, for: .nemotron)
        store.write(Record(loading: flight(77)), for: .parakeet)
        store.write(Record(loading: hours), for: .diarizer)
        store.write(struck(2), for: .speechDetection)

        launch(markers: dir).clearOwnMarkersAtTermination()

        #expect(store.read(.whisper) == nil)
        #expect(store.read(.nemotron) == struck(1))
        #expect(store.read(.parakeet) == Record(loading: flight(77)))
        // Hours into its load — the lid was closed — and still not a death.
        #expect(store.read(.diarizer) == nil)
        #expect(store.read(.speechDetection) == struck(2))
        #expect(names(in: dir) == ["nemotron.json", "parakeet.json", "speechDetection.json"])
    }

    // MARK: Launch

    @Test("The launch after a crash in a load: strike one, the compiled cache gone and nothing beside it, preload skipped")
    func launchAfterACrash() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, siblings) = try makeCaches(in: root)

        // The run that dies: the load never returns, the marker stays.
        let store = ModelLoadMarkerStore(directory: markers)
        store.write(Policy.whileLoading(nil, flight: flight(41)), for: .whisper)

        let next = launch(markers: markers, cache: cache, crashed: true)
        let plan = try #require(next.checkAtLaunch(now: now))
        #expect(plan.died == [.whisper])
        #expect(plan.struck == [.whisper])
        #expect(next.skipsLaunchPreload)
        #expect(next.held.isEmpty)
        #expect(next.announced.isEmpty)
        #expect(next.heldMessage(for: .whisper) == nil)
        #expect(store.read(.whisper) == struck(1))
        // Moved aside at once — nothing can load from it any more…
        #expect(!fm.fileExists(atPath: cache.path))
        // …and deleted after, with nothing left of it.
        await next.cleanup?.value
        #expect(names(in: cache.deletingLastPathComponent()) == ["Cache.db", "org.sparkle-project.Sparkle"])
        for sibling in siblings { #expect(fm.fileExists(atPath: sibling.path)) }

        // The launch after that one, with nothing new: back to normal.
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let calm = launch(markers: markers, cache: cache, crashed: false)
        let calmPlan = try #require(calm.checkAtLaunch(now: now))
        #expect(calmPlan.died.isEmpty)
        #expect(!calm.skipsLaunchPreload)
        await calm.cleanup?.value
        #expect(fm.fileExists(atPath: cache.path))
        #expect(store.read(.whisper) == struck(1))
    }

    @Test("Two crashes in a row hold the engine; the person's ask lifts it, a third crash holds it again")
    func twoCrashesThenLift() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)
        let store = ModelLoadMarkerStore(directory: markers)

        // Run 1 dies in Parakeet's load.
        let run1 = launch(markers: markers, cache: cache, pid: 41)
        let hang1 = Hold()
        let load1 = Task { @MainActor in await run1.run(.parakeet) { await hang1.wait() } }
        #expect(await eventually { hang1.entered })

        // Run 2 finds it, loads again, dies again.
        let run2 = launch(markers: markers, cache: cache, pid: 42)
        #expect(run2.checkAtLaunch(now: now)?.struck == [.parakeet])
        #expect(run2.held.isEmpty)
        await run2.cleanup?.value
        let hang2 = Hold()
        let load2 = Task { @MainActor in await run2.run(.parakeet) { await hang2.wait() } }
        #expect(await eventually { hang2.entered })
        #expect(store.read(.parakeet)?.strikes == 1)
        #expect(store.read(.parakeet)?.loading?.pid == 42)

        // Run 3: held, and said.
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let run3 = launch(markers: markers, cache: cache, pid: 43)
        let plan = try #require(run3.checkAtLaunch(now: now))
        #expect(plan.announce == [.parakeet])
        #expect(run3.held == [.parakeet])
        #expect(run3.announced == [.parakeet])
        #expect(run3.skipsLaunchPreload)
        #expect(run3.heldMessage(for: .parakeet) == ModelLoadGuard.heldMessage(naming: .parakeet))
        #expect(run3.heldMessage(for: .whisper) == nil)
        #expect(throws: ModelLoadHeldError.self) { try run3.refuseIfHeld(.parakeet) }
        #expect(throws: Never.self) { try run3.refuseIfHeld(.whisper) }
        await run3.cleanup?.value
        #expect(!fm.fileExists(atPath: cache.path))

        // Run 4, nothing asked: still held, quietly, with the preload on
        // for the engines that aren't.
        let run4 = launch(markers: markers, cache: cache, pid: 44, crashed: false)
        #expect(run4.checkAtLaunch(now: now)?.announce.isEmpty == true)
        #expect(run4.held == [.parakeet])
        #expect(run4.announced.isEmpty)
        #expect(!run4.skipsLaunchPreload)
        await run4.cleanup?.value

        // The person asks: lifted for this run and the ones after.
        run4.liftHolds([.whisper], now: now)
        #expect(run4.held == [.parakeet])
        run4.liftHolds(now: now)
        #expect(run4.held.isEmpty)
        #expect(store.read(.parakeet) == struck(1))
        let run5 = launch(markers: markers, cache: cache, pid: 45, crashed: false)
        run5.checkAtLaunch(now: now)
        #expect(run5.held.isEmpty)

        // It crashes in the load once more: held again at once.
        let hang5 = Hold()
        let load5 = Task { @MainActor in await run5.run(.parakeet) { await hang5.wait() } }
        #expect(await eventually { hang5.entered })
        let run6 = launch(markers: markers, cache: cache, pid: 46)
        run6.checkAtLaunch(now: now)
        #expect(run6.held == [.parakeet])
        #expect(run6.announced == [.parakeet])

        // Asked again, and this time the load works: the strikes are gone.
        run6.liftHolds(now: now)
        await run6.run(.parakeet) {}
        #expect(store.read(.parakeet) == nil)
        let run7 = launch(markers: markers, cache: cache, pid: 47)
        #expect(run7.checkAtLaunch(now: now) == Policy.LaunchPlan())

        for hold in [hang1, hang2, hang5] { hold.open() }
        for load in [load1, load2, load5] { await load.value }
        await run5.cleanup?.value
        await run6.cleanup?.value
        await run7.cleanup?.value
    }

    @Test("A hold doesn't reach the next build, and an old strike doesn't reach the next crash")
    func expiryOnDisk() throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let store = ModelLoadMarkerStore(directory: dir)
        store.write(struck(2), for: .whisper)
        store.write(struck(1, at: now.addingTimeInterval(-8 * 24 * 60 * 60)), for: .parakeet)
        store.write(struck(1, at: now.addingTimeInterval(-24 * 60 * 60)), for: .diarizer)

        // The same build, a day on: Whisper held, the old strike dropped.
        let same = launch(markers: dir, crashed: false)
        same.checkAtLaunch(now: now)
        #expect(same.held == [.whisper])
        #expect(store.read(.parakeet) == nil)
        #expect(store.read(.diarizer) == struck(1, at: now.addingTimeInterval(-24 * 60 * 60)))

        // The next build: nothing held, nothing left on disk.
        let updated = launch(markers: dir, crashed: false, build: "test (2)")
        #expect(updated.checkAtLaunch(now: now)?.held.isEmpty == true)
        #expect(updated.held.isEmpty)
        #expect(names(in: dir).isEmpty)
    }

    @Test("A marker from a download window: the preload is skipped, the compiled cache stays")
    func deathInADownloadWindow() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)
        let store = ModelLoadMarkerStore(directory: markers)
        store.write(Policy.whileLoading(nil, flight: flight(41, mayDownload: true)), for: .nemotron)

        let next = launch(markers: markers, cache: cache, crashed: true)
        let plan = try #require(next.checkAtLaunch(now: now))
        #expect(plan.died == [.nemotron])
        #expect(plan.struck.isEmpty)
        #expect(next.skipsLaunchPreload)
        await next.cleanup?.value
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
        #expect(store.read(.nemotron) == nil)
    }

    @Test("A marker from a run without the crash handler is struck even when Sentry now says «did not crash»")
    func noHandlerInThatRun() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let store = ModelLoadMarkerStore(directory: root.appendingPathComponent("model-load-guard"))
        let (cache, _) = try makeCaches(in: root)

        // Crash reports were off in the run that died: its marker says no
        // handler. They are on again now, and Sentry's «did not crash» is
        // about some earlier run.
        let died = launch(markers: store.directory, pid: 41, handler: false)
        let hang = Hold()
        let load = Task { @MainActor in await died.run(.whisper) { await hang.wait() } }
        #expect(await eventually { hang.entered })
        #expect(store.read(.whisper)?.loading?.crashHandlerInstalled == false)

        let next = launch(markers: store.directory, cache: cache, crashed: false)
        let plan = try #require(next.checkAtLaunch(now: now))
        #expect(plan.struck == [.whisper])
        #expect(next.skipsLaunchPreload)
        #expect(!fm.fileExists(atPath: cache.path))
        await next.cleanup?.value
        #expect(store.read(.whisper) == struck(1))

        // The same death with the handler in that run: on record as not a crash.
        store.write(Policy.whileLoading(nil, flight: flight(41, handler: true)), for: .parakeet)
        let other = launch(markers: store.directory, cache: cache, crashed: false)
        #expect(other.checkAtLaunch(now: now)?.struck.isEmpty == true)
        #expect(store.read(.parakeet) == nil)
        await other.cleanup?.value

        hang.open()
        await load.value
    }

    @Test("With another Daisy running the compiled cache stays where it is; the preload is skipped and the strike counted")
    func anotherInstanceRunning() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, siblings) = try makeCaches(in: root)
        let store = ModelLoadMarkerStore(directory: markers)
        store.write(Policy.whileLoading(nil, flight: flight(41)), for: .whisper)

        let next = launch(markers: markers, cache: cache, crashed: true, anotherInstance: true)
        let plan = try #require(next.checkAtLaunch(now: now))
        #expect(plan.died == [.whisper])
        #expect(plan.struck == [.whisper])
        #expect(plan.purgeWithheld)
        #expect(!plan.purgeCompiledCache)
        #expect(next.skipsLaunchPreload)
        await next.cleanup?.value
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
        #expect(names(in: cache.deletingLastPathComponent())
                == ["Cache.db", "com.apple.e5rt.e5bundlecache", "org.sparkle-project.Sparkle"])
        for sibling in siblings { #expect(fm.fileExists(atPath: sibling.path)) }
        #expect(store.read(.whisper) == struck(1))
    }

    @Test("A hold set ten days ago, lifted today: the crash after it holds again at the next launch")
    func agedHoldLiftedOnDisk() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let store = ModelLoadMarkerStore(directory: dir)
        store.write(struck(2, at: now.addingTimeInterval(-10 * 24 * 60 * 60)), for: .whisper)

        let today = launch(markers: dir, pid: 41, crashed: false)
        today.checkAtLaunch(now: now)
        #expect(today.held == [.whisper])
        today.liftHolds(now: now)
        #expect(store.read(.whisper) == struck(1))
        let hang = Hold()
        let load = Task { @MainActor in await today.run(.whisper) { await hang.wait() } }
        #expect(await eventually { hang.entered })

        let tomorrow = launch(markers: dir, pid: 42, crashed: true)
        let plan = try #require(tomorrow.checkAtLaunch(now: now.addingTimeInterval(24 * 60 * 60)))
        #expect(plan.struck == [.whisper])
        #expect(tomorrow.held == [.whisper])
        #expect(tomorrow.announced == [.whisper])

        hang.open()
        await load.value
    }

    /// A launch with Sentry's answer given as it is — for the first-launch
    /// rule, which reads all three.
    private func firstLaunch(markers: URL, cache: URL, lastRun: CrashReports.LastRun,
                             anotherInstance: Bool = false) -> ModelLoadGuard {
        ModelLoadGuard(store: ModelLoadMarkerStore(directory: markers), compiledCache: cache,
                       pid: me, build: build, isAlive: { _ in false }, lastRun: { lastRun },
                       crashHandlerInstalled: { true }, anotherInstanceRunning: { anotherInstance },
                       downloadWindowIsOpen: { false }, checkFiles: { _ in }, afterLift: { _ in })
    }

    @Test("A Mac the unguarded builds crashed on: the first guarded launch moves the cache aside, preloads, strikes nothing — once")
    func firstLaunchAfterACrashedRun() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("Application Support/Daisy/model-load-guard")
        let (cache, siblings) = try makeCaches(in: root)
        #expect(!ModelLoadMarkerStore(directory: markers).directoryExists)

        let first = firstLaunch(markers: markers, cache: cache, lastRun: .crashed)
        let plan = try #require(first.checkAtLaunch(now: now))
        #expect(plan.purgeCompiledCache && plan.firstLaunchPurge)
        #expect(plan.struck.isEmpty && plan.died.isEmpty)
        #expect(!first.skipsLaunchPreload)
        #expect(first.held.isEmpty)
        #expect(first.announced.isEmpty)
        #expect(!fm.fileExists(atPath: cache.path))
        await first.cleanup?.value
        #expect(names(in: cache.deletingLastPathComponent()) == ["Cache.db", "org.sparkle-project.Sparkle"])
        for sibling in siblings { #expect(fm.fileExists(atPath: sibling.path)) }
        // The folder is there now, empty: the rule has had its one turn.
        #expect(ModelLoadMarkerStore(directory: markers).directoryExists)
        #expect(names(in: markers).isEmpty)

        // The second launch, the run before it crashed too, still no marker:
        // nothing says it was a load. The cache it compiled stays.
        try fm.createDirectory(at: cache.appendingPathComponent("26A428"), withIntermediateDirectories: true)
        let second = firstLaunch(markers: markers, cache: cache, lastRun: .crashed)
        #expect(second.checkAtLaunch(now: now) == Policy.LaunchPlan())
        #expect(!second.skipsLaunchPreload)
        await second.cleanup?.value
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428").path))
    }

    @Test("The first guarded launch leaves the cache alone when the last run didn't crash, or nobody knows",
          arguments: [CrashReports.LastRun.didNotCrash, .unknown])
    func firstLaunchWithoutACrash(lastRun: CrashReports.LastRun) async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)

        let first = firstLaunch(markers: markers, cache: cache, lastRun: lastRun)
        #expect(first.checkAtLaunch(now: now) == Policy.LaunchPlan())
        #expect(!first.skipsLaunchPreload)
        await first.cleanup?.value
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
        // Still the first and only first launch.
        #expect(ModelLoadMarkerStore(directory: markers).directoryExists)
    }

    @Test("The first guarded launch after a crashed run, with another Daisy running: the cache stays")
    func firstLaunchWithAnotherInstance() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)

        let first = firstLaunch(markers: markers, cache: cache, lastRun: .crashed, anotherInstance: true)
        let plan = try #require(first.checkAtLaunch(now: now))
        #expect(!plan.purgeCompiledCache && !plan.firstLaunchPurge)
        #expect(plan.purgeWithheld)
        #expect(!first.skipsLaunchPreload)
        await first.cleanup?.value
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
        #expect(ModelLoadMarkerStore(directory: markers).directoryExists)
    }

    @Test("A marker folder that can't be made doesn't fail the launch; the rule fires again next time")
    func firstLaunchFolderCannotBeMade() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: blocked)
        let markers = blocked.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)

        for _ in 0..<2 {
            try fm.createDirectory(at: cache.appendingPathComponent("26A428"), withIntermediateDirectories: true)
            let launch = firstLaunch(markers: markers, cache: cache, lastRun: .crashed)
            #expect(launch.checkAtLaunch(now: now)?.firstLaunchPurge == true)
            #expect(!launch.skipsLaunchPreload)
            #expect(await launch.run(.whisper) { 1 } == 1)
            await launch.cleanup?.value
            #expect(!fm.fileExists(atPath: cache.path))
            #expect(!ModelLoadMarkerStore(directory: markers).directoryExists)
        }
    }

    @Test("Another Daisy still running keeps its marker, and nothing is purged")
    func anotherDaisyIsLoading() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)
        let store = ModelLoadMarkerStore(directory: markers)
        let theirs = Policy.whileLoading(nil, flight: flight(41))
        store.write(theirs, for: .whisper)

        let next = launch(markers: markers, cache: cache, alive: [41])
        let plan = try #require(next.checkAtLaunch(now: now))
        #expect(plan.died.isEmpty)
        #expect(!next.skipsLaunchPreload)
        await next.cleanup?.value
        #expect(store.read(.whisper) == theirs)
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
    }

    @Test("A Daisy that quit between the read and the check is not a death: the marker is read again")
    func ownerQuitMeanwhile() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, _) = try makeCaches(in: root)
        let store = ModelLoadMarkerStore(directory: markers)
        var theirs = struck(1)
        theirs.loading = flight(41)
        store.write(theirs, for: .whisper)

        // The language relaunch: the old instance is alive when the marker
        // is read and gone when its pid is asked about — having cleared
        // its marker on the way out, as a quit does.
        let next = ModelLoadGuard(
            store: store, compiledCache: cache, pid: me, build: build,
            isAlive: { pid in
                launch(markers: markers, pid: pid).clearOwnMarkersAtTermination()
                return false
            },
            lastRun: { .crashed }, crashHandlerInstalled: { true }, anotherInstanceRunning: { false },
            downloadWindowIsOpen: { false }, checkFiles: { _ in }, afterLift: { _ in })
        let plan = try #require(next.checkAtLaunch(now: now))
        #expect(plan.died.isEmpty)
        #expect(plan.struck.isEmpty)
        #expect(!next.skipsLaunchPreload)
        await next.cleanup?.value
        #expect(store.read(.whisper) == struck(1))
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
    }

    @Test("A marker carrying this process's own id is a dead run's, its number reused")
    func ownPidAtLaunchIsStale() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let store = ModelLoadMarkerStore(directory: root)
        store.write(Policy.whileLoading(nil, flight: flight(me)), for: .whisper)
        // Even a check that calls every pid alive: nothing of this
        // process's can be loading before its launch check.
        let next = ModelLoadGuard(store: store, compiledCache: nil, pid: me, build: build,
                                  isAlive: { _ in true }, lastRun: { .crashed },
                                  crashHandlerInstalled: { true }, anotherInstanceRunning: { false },
                                  downloadWindowIsOpen: { false }, checkFiles: { _ in }, afterLift: { _ in })
        #expect(next.checkAtLaunch(now: now)?.died == [.whisper])
        #expect(next.skipsLaunchPreload)
        #expect(store.read(.whisper) == struck(1))
    }

    // MARK: Lifting

    @Test("A lift checks the files first, once — a second press starts no second check — and resets the engines")
    func liftBeforeLoading() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let store = ModelLoadMarkerStore(directory: dir)
        for engine in [ModelLoadEngine.parakeet, .diarizer, .whisper] { store.write(struck(2), for: engine) }

        final class Seen {
            var checked: [ModelLoadEngine] = []
            var reset: [Set<ModelLoadEngine>] = []
            var heldDuringCheck = true
            var loadGuard: ModelLoadGuard?
        }
        let seen = Seen()
        let slow = Hold()
        let made = ModelLoadGuard(
            store: store, compiledCache: nil, pid: me, build: build,
            isAlive: { _ in false }, lastRun: { .didNotCrash }, crashHandlerInstalled: { true },
            anotherInstanceRunning: { false }, downloadWindowIsOpen: { false },
            checkFiles: { engine in
                seen.checked.append(engine)
                // The hold is still on while the files are checked.
                if seen.loadGuard?.held.contains(engine) != true { seen.heldDuringCheck = false }
                if engine == .whisper { await slow.wait() }
            },
            afterLift: { seen.reset.append($0) })
        seen.loadGuard = made
        made.checkAtLaunch(now: now)
        #expect(made.held == [.whisper, .parakeet, .diarizer])

        let first = Task { @MainActor in await made.liftHoldsBeforeLoading(now: now) }
        #expect(await eventually { slow.entered })
        let second = Task { @MainActor in await made.liftHoldsBeforeLoading(now: now) }
        for _ in 0..<20 { await Task.yield() }
        #expect(made.held == [.whisper, .parakeet, .diarizer])
        slow.open()
        await first.value
        await second.value

        #expect(made.held.isEmpty)
        #expect(seen.checked == [.whisper, .parakeet, .diarizer])
        #expect(seen.heldDuringCheck)
        #expect(seen.reset == [[.whisper, .parakeet, .diarizer]])
        for engine in [ModelLoadEngine.parakeet, .diarizer, .whisper] {
            #expect(store.read(engine) == struck(1))
        }
        // Nothing held: a later press checks nothing.
        await made.liftHoldsBeforeLoading()
        #expect(seen.checked.count == 3)
        #expect(seen.reset.count == 1)
        seen.loadGuard = nil
    }

    // MARK: The compiled cache

    @Test("Only the app's own compiled cache is ever moved: by name, never the one straight in Caches; a missing one is a no-op")
    func moveAsideIsNarrow() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Caches/app.essazanov.Daisy", isDirectory: true)
        let other = app.appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(CompiledModelCache.moveAside(other) == nil)
        #expect(CompiledModelCache.moveAside(app) == nil)
        #expect(CompiledModelCache.removeMovedAside(beside: other) == 0)
        #expect(fm.fileExists(atPath: other.path))

        // What an empty bundle id would have pointed at: the system's own,
        // straight in Caches. Never touched, nor anything beside it.
        let systems = root.appendingPathComponent("Caches/com.apple.e5rt.e5bundlecache", isDirectory: true)
        try fm.createDirectory(at: systems.appendingPathComponent("26A428"), withIntermediateDirectories: true)
        let lookalike = root.appendingPathComponent("Caches/com.apple.e5rt.e5bundlecache.daisy-purge-X", isDirectory: true)
        try fm.createDirectory(at: lookalike, withIntermediateDirectories: true)
        #expect(!CompiledModelCache.isAppsOwn(systems))
        #expect(CompiledModelCache.moveAside(systems) == nil)
        #expect(CompiledModelCache.removeMovedAside(beside: systems) == 0)
        #expect(fm.fileExists(atPath: systems.appendingPathComponent("26A428").path))
        #expect(fm.fileExists(atPath: lookalike.path))

        let cache = app.appendingPathComponent(Policy.compiledCacheFolderName, isDirectory: true)
        #expect(CompiledModelCache.isAppsOwn(cache))
        #expect(CompiledModelCache.moveAside(cache) == nil)
        #expect(CompiledModelCache.removeMovedAside(beside: cache) == 0)
        #expect(names(in: app) == ["org.sparkle-project.Sparkle"])

        try fm.createDirectory(at: cache.appendingPathComponent("26A428"), withIntermediateDirectories: true)
        let aside = try #require(CompiledModelCache.moveAside(cache))
        #expect(aside.deletingLastPathComponent().path == app.path)
        #expect(aside.lastPathComponent.hasPrefix("com.apple.e5rt.e5bundlecache.daisy-purge-"))
        #expect(!fm.fileExists(atPath: cache.path))
        #expect(fm.fileExists(atPath: aside.appendingPathComponent("26A428").path))
        #expect(CompiledModelCache.removeMovedAside(beside: cache) == 1)
        #expect(names(in: app) == ["org.sparkle-project.Sparkle"])
    }

    @Test("A moved-aside cache an earlier launch didn't live to delete goes at the next launch")
    func leftoverIsSwept() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let markers = root.appendingPathComponent("model-load-guard")
        let (cache, siblings) = try makeCaches(in: root)
        let leftover = cache.deletingLastPathComponent()
            .appendingPathComponent("com.apple.e5rt.e5bundlecache.daisy-purge-OLD", isDirectory: true)
        try fm.createDirectory(at: leftover.appendingPathComponent("26A428"), withIntermediateDirectories: true)

        let next = launch(markers: markers, cache: cache, crashed: false)
        #expect(next.checkAtLaunch(now: now) == Policy.LaunchPlan())
        await next.cleanup?.value
        #expect(!fm.fileExists(atPath: leftover.path))
        // No death: the cache itself stays, and so does everything else.
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("26A428/ABCDEF/model.bundle").path))
        for sibling in siblings { #expect(fm.fileExists(atPath: sibling.path)) }
    }

    // MARK: Real processes

    /// A process killed with its marker on disk, as a Force Quit in the
    /// middle of a load leaves it. Returns the dead pid.
    private func killedChild(marking engine: ModelLoadEngine, in store: ModelLoadMarkerStore) throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let pid = child.processIdentifier
        #expect(ModelLoadGuard.processExists(pid))
        // Alive, but not a Daisy: after a restart a marker's pid can be anyone's.
        #expect(!ModelLoadGuard.isAnotherRunningDaisy(pid))
        store.write(Policy.whileLoading(store.read(engine), flight: flight(pid)), for: engine)
        kill(pid, SIGKILL)
        child.waitUntilExit()
        #expect(!ModelLoadGuard.processExists(pid))
        #expect(!ModelLoadGuard.isAnotherRunningDaisy(pid))
        return pid
    }

    /// The app's own liveness check, everything else the test's.
    private func realLaunch(_ store: ModelLoadMarkerStore, cache: URL, crashed: Bool) -> ModelLoadGuard {
        ModelLoadGuard(store: store, compiledCache: cache, pid: me, build: build,
                       lastRun: { crashed ? .crashed : .didNotCrash }, crashHandlerInstalled: { true },
                       anotherInstanceRunning: { false }, downloadWindowIsOpen: { false },
                       checkFiles: { _ in }, afterLift: { _ in })
    }

    @Test("A killed process and no evidence of a crash: the cache is purged and the preload skipped, but no strike — twice over")
    func killedWithoutCrashEvidence() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let store = ModelLoadMarkerStore(directory: root.appendingPathComponent("model-load-guard"))
        let (cache, siblings) = try makeCaches(in: root)

        for _ in 0..<2 {
            _ = try killedChild(marking: .whisper, in: store)
            try fm.createDirectory(at: cache.appendingPathComponent("26A428"), withIntermediateDirectories: true)
            let next = realLaunch(store, cache: cache, crashed: false)
            let plan = try #require(next.checkAtLaunch(now: now))
            #expect(plan.died == [.whisper])
            #expect(plan.struck.isEmpty)
            #expect(next.skipsLaunchPreload)
            #expect(next.held.isEmpty)
            #expect(next.announced.isEmpty)
            #expect(!fm.fileExists(atPath: cache.path))
            await next.cleanup?.value
            #expect(names(in: cache.deletingLastPathComponent()) == ["Cache.db", "org.sparkle-project.Sparkle"])
            // Nothing to remember: the marker's file is gone.
            #expect(store.read(.whisper) == nil)
            #expect(store.readAll().isEmpty)
        }
        for sibling in siblings { #expect(fm.fileExists(atPath: sibling.path)) }
    }

    @Test("A killed process and evidence of a crash: a strike each time, and the second holds")
    func killedWithCrashEvidence() async throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let store = ModelLoadMarkerStore(directory: root.appendingPathComponent("model-load-guard"))
        let (cache, _) = try makeCaches(in: root)

        _ = try killedChild(marking: .whisper, in: store)
        let first = realLaunch(store, cache: cache, crashed: true)
        #expect(first.checkAtLaunch(now: now)?.struck == [.whisper])
        #expect(first.skipsLaunchPreload)
        #expect(first.held.isEmpty)
        #expect(!fm.fileExists(atPath: cache.path))
        await first.cleanup?.value
        #expect(store.read(.whisper) == struck(1))

        _ = try killedChild(marking: .whisper, in: store)
        let second = realLaunch(store, cache: cache, crashed: true)
        #expect(second.checkAtLaunch(now: now)?.announce == [.whisper])
        #expect(second.held == [.whisper])
        #expect(second.announced == [.whisper])
        await second.cleanup?.value
        #expect(store.read(.whisper) == struck(2))

        #expect(!ModelLoadGuard.processExists(0))
        #expect(!ModelLoadGuard.processExists(-1))
    }

    @Test("This process is a running Daisy: a second instance's marker is recognised as alive")
    func thisProcessIsADaisy() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(ModelLoadGuard.processExists(pid))
        #expect(ModelLoadGuard.isAnotherRunningDaisy(pid))
    }
}

@MainActor
@Suite("Model load guard: what the person sees")
struct ModelLoadHoldTests {
    private func held(_ engines: [ModelLoadEngine], announced: Bool = false) -> (ModelLoadGuard, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLoadHoldTests-\(UUID().uuidString)", isDirectory: true)
        let store = ModelLoadMarkerStore(directory: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for engine in engines {
            // Announced: the second crash is this launch's.
            store.write(.init(strikes: announced ? 1 : 2, strikesBuild: "test (1)", lastStrikeAt: now,
                              loading: announced ? .init(pid: 41, startedAt: now, build: "test (1)") : nil),
                        for: engine)
        }
        let loadGuard = ModelLoadGuard(store: store, compiledCache: nil, pid: 500, build: "test (1)",
                                       isAlive: { _ in false }, lastRun: { .crashed },
                                       crashHandlerInstalled: { true }, anotherInstanceRunning: { false },
                                       downloadWindowIsOpen: { false }, checkFiles: { _ in }, afterLift: { _ in })
        loadGuard.checkAtLaunch(now: now)
        return (loadGuard, dir)
    }

    @Test("The held message names the model and the button that lifts it")
    func heldMessage() {
        #expect(ModelLoadGuard.heldMessage(naming: .whisper)
                == "Daisy closed twice in a row while loading the speech model. It won’t load it on its own any more. Press Download and check to try again")
        #expect(ModelLoadGuard.heldMessage(naming: .whisperJob) == ModelLoadGuard.heldMessage(naming: .whisper))
        #expect(ModelLoadGuard.heldMessage(naming: .parakeet).contains("while loading the fast dictation model."))
        #expect(ModelLoadGuard.heldMessage(naming: .speechDetection).contains("while loading speech detection."))
        #expect(ModelLoadGuard.heldMessage(naming: .diarizer).contains("while loading speaker separation."))
        #expect(ModelLoadGuard.heldMessage(naming: .nemotron).contains("while loading the live dictation model."))
    }

    @Test("One line per held model, the meeting model and a job's model as one")
    func heldMessages() {
        let (loadGuard, dir) = held([.diarizer, .whisperJob, .whisper])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(loadGuard.heldMessages == [ModelLoadGuard.heldMessage(naming: .whisper),
                                           ModelLoadGuard.heldMessage(naming: .diarizer)])
        loadGuard.liftHolds([.whisper, .whisperJob])
        #expect(loadGuard.heldMessages == [ModelLoadGuard.heldMessage(naming: .diarizer)])
    }

    @Test("The launch notice names every model it is about, each once")
    func launchNoticeNamesAll() {
        let en = Locale(identifier: "en")
        #expect(ModelLoadGuard.launchNoticeText(for: [.whisper], locale: en)
                == "Daisy closed twice while loading the speech model")
        #expect(ModelLoadGuard.launchNoticeText(for: [.whisper, .whisperJob], locale: en)
                == "Daisy closed twice while loading the speech model")
        #expect(ModelLoadGuard.launchNoticeText(for: [.whisper, .parakeet], locale: en)
                == "Daisy closed twice while loading the speech model and the fast dictation model")
        let three = ModelLoadGuard.launchNoticeText(for: [.whisper, .parakeet, .diarizer], locale: en)
        for name in ["the speech model", "the fast dictation model", "speaker separation"] {
            #expect(three.contains(name), "\(three)")
        }
        // What the guard hands the notice: all of them, in the engines' order.
        let (loadGuard, dir) = held([.diarizer, .whisper, .parakeet], announced: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(loadGuard.announced == [.whisper, .parakeet, .diarizer])
    }

    @Test("A held engine brings the preparation card up, whichever engine it is")
    func heldNeedsAttention() {
        // No `AppSettings` here: it lives on the real preferences. The
        // check takes the two settings it reads as values, and a hold
        // answers before either is looked at.
        for engine in ModelLoadEngine.allCases {
            let (loadGuard, dir) = held([engine])
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(ModelPreparation().needsAttention(dictationEngine: .appleSpeech, usesNemotronLive: false,
                                                      loadGuard: loadGuard))
        }
    }

    @Test("On an Intel Mac a held Faster gives its reason, not «pick Faster»")
    func intelRefusalSaysHeld() {
        let held = ModelLoadGuard.heldMessage(naming: .parakeet)
        #expect(RecordingSession.dictationRefusalOnUnsupportedMac(engine: .parakeet, heldParakeet: held) == held)
        #expect(RecordingSession.dictationRefusalOnUnsupportedMac(engine: .parakeet, heldParakeet: nil)
                == RecordingSession.dictationNeedsFastEngineMessage)
        // Another engine chosen: Parakeet's hold is not why this dictation can't run.
        #expect(RecordingSession.dictationRefusalOnUnsupportedMac(engine: .appleSpeech, heldParakeet: held)
                == RecordingSession.dictationNeedsFastEngineMessage)
        #expect(RecordingSession.dictationRefusalOnUnsupportedMac(engine: .whisper, heldParakeet: held)
                == RecordingSession.dictationNeedsFastEngineMessage)
    }

    @Test("Every new line has a Russian translation: «ты», no full stop at the end")
    func russianStrings() throws {
        let ru = try #require(Bundle(for: RecordingSession.self).path(forResource: "ru", ofType: "lproj")
            .flatMap(Bundle.init(path:)))
        let expected = [
            "Daisy closed twice in a row while loading %@. It won’t load it on its own any more. Press Download and check to try again":
                "Daisy дважды подряд закрылась, пока загружала %@, и больше не делает этого сама. Нажми «Скачать и проверить», чтобы попробовать ещё раз",
            "Daisy closed twice while loading %@": "Daisy дважды закрылась, пока загружала %@",
            "modelLoad.name.whisper": "модель речи",
            "modelLoad.name.parakeet": "модель быстрой диктовки",
            "modelLoad.name.speechDetection": "определение речи",
            "modelLoad.name.diarizer": "разделение спикеров",
            "modelLoad.name.nemotron": "модель живой диктовки",
        ]
        for (key, value) in expected {
            let found = ru.localizedString(forKey: key, value: "∅", table: nil)
            #expect(found == value, "RU for \(key)")
            #expect(!found.contains("ьте"), "RU uses «ты»: \(found)")
            #expect(!found.hasSuffix("."), "no full stop at the end: \(found)")
        }
        // The button the message names is called the same on the card.
        let button = ru.localizedString(forKey: "Download and check", value: "∅", table: nil)
        #expect(expected.values.contains { $0.contains("«\(button)»") })
    }

    @Test("The keyed names have their English too")
    func englishNames() {
        #expect(ModelLoadEngine.whisper.nameAfterLoading == "the speech model")
        #expect(ModelLoadEngine.whisperJob.nameAfterLoading == "the speech model")
        #expect(ModelLoadEngine.parakeet.nameAfterLoading == "the fast dictation model")
        #expect(ModelLoadEngine.speechDetection.nameAfterLoading == "speech detection")
        #expect(ModelLoadEngine.diarizer.nameAfterLoading == "speaker separation")
        #expect(ModelLoadEngine.nemotron.nameAfterLoading == "the live dictation model")
    }
}

/// A load that hangs until the test lets it go.
@MainActor
private final class Hold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var entered = false

    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func eventually(_ timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
