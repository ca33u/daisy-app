//
//  StartPreflightTests.swift
//  DaisyTests
//
//  `RecordingSession.start()` refuses in exactly two situations, and
//  1.0.7.71 shipped a third that nobody meant: "the model isn't loaded
//  yet" — the first seconds after launch, a cold reload after memory
//  pressure — was treated as a failure and sent the user to Settings,
//  which meant a calendar auto-start a minute after the Mac booted
//  recorded nothing. These lock the decision table so that can't
//  come back quietly.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Start preflight")
struct StartPreflightTests {

    typealias Preflight = RecordingSession.StartPreflight

    // MARK: - Waiting is not refusing

    @Test("A model that merely hasn't loaded yet is waited for, not refused",
          arguments: [
            WhisperEngine.LoadState.notLoaded,
            .downloading(progress: 0.3),
            .loading(status: "Loading transcription model…"),
          ])
    func notReadyIsNotARefusal(state: WhisperEngine.LoadState) {
        // Cached model, online — every intermediate state proceeds and
        // lets `start()` wait with the explainer toast and retries.
        #expect(Preflight.decide(
            hasShownFirstRun: true, whisperState: state, modelIsCached: true, isOnline: true
        ) == .proceed)
        // Cached model, OFFLINE — still proceeds: a cached model needs
        // no network to load. (The 1.0.7.71 regression fired here too.)
        #expect(Preflight.decide(
            hasShownFirstRun: true, whisperState: state, modelIsCached: true, isOnline: false
        ) == .proceed)
        // No cache but online — proceeds; the wait path downloads.
        #expect(Preflight.decide(
            hasShownFirstRun: true, whisperState: state, modelIsCached: false, isOnline: true
        ) == .proceed)
    }

    @Test("A ready model always proceeds")
    func readyProceeds() {
        for cached in [true, false] {
            for online in [true, false] {
                #expect(Preflight.decide(
                    hasShownFirstRun: true, whisperState: .ready, modelIsCached: cached, isOnline: online
                ) == .proceed)
            }
        }
    }

    // MARK: - The two real refusals

    @Test("Refused only when the model isn't on disk AND there's no network to fetch it",
          arguments: [
            WhisperEngine.LoadState.notLoaded,
            .downloading(progress: 0.0),
            .failed("offline"),
          ])
    func refusedWhenLoadingIsImpossible(state: WhisperEngine.LoadState) {
        #expect(Preflight.decide(
            hasShownFirstRun: true, whisperState: state, modelIsCached: false, isOnline: false
        ) == .modelCannotLoad)
    }

    @Test("A failed state alone is not a refusal — the wait path retries it")
    func failedIsRetriedWhenRetryCouldWork() {
        // The 2026-06-16 cold-start race lands here: `.failed`
        // transiently, and the second attempt works. With a cached
        // model, or with network, `start()` must try again rather than
        // send the user to Settings.
        #expect(Preflight.decide(
            hasShownFirstRun: true, whisperState: .failed("transient"), modelIsCached: true, isOnline: false
        ) == .proceed)
        #expect(Preflight.decide(
            hasShownFirstRun: true, whisperState: .failed("transient"), modelIsCached: false, isOnline: true
        ) == .proceed)
    }

    @Test("Unfinished onboarding is refused regardless of the model")
    func onboardingIncomplete() {
        for state in [WhisperEngine.LoadState.ready, .notLoaded, .failed("x")] {
            #expect(Preflight.decide(
                hasShownFirstRun: false, whisperState: state, modelIsCached: true, isOnline: true
            ) == .onboardingIncomplete)
        }
    }

    // MARK: - Model recovery folder

    @Test("Parked model copies are pruned by count and by age")
    func recoveryPruning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        func park(_ name: String, ageDays: Double) throws {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("weight.bin"))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: dir.path
            )
        }
        // Four copies: two fresh, one fresh-but-third, one ancient.
        try park("a-newest", ageDays: 0.1)
        try park("b-second", ageDays: 1)
        try park("c-third",  ageDays: 2)
        try park("d-ancient", ageDays: 30)
        // A stray file at the root must be left alone.
        try Data([1]).write(to: root.appendingPathComponent("notes.txt"))

        WhisperEngine.pruneModelRecovery(at: root, now: now)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(remaining.contains("a-newest"))
        #expect(remaining.contains("b-second"))
        #expect(!remaining.contains("c-third"))    // over the keep count
        #expect(!remaining.contains("d-ancient"))  // over the age limit
        #expect(remaining.contains("notes.txt"))
    }

    @Test("A freshly parked copy survives pruning even if the model itself is months old")
    func recoveryPruningKeepsJustParkedCopy() throws {
        // `downloadAgain` moves the old model folder into recovery. A
        // same-volume move keeps the folder's mtime — the download
        // date — so a model in use since spring would look 100+ days
        // old the instant it was parked, and be deleted by the prune
        // that runs right after. The park path stamps the mtime; this
        // pins the policy side: a copy stamped "now" is kept.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let parked = root.appendingPathComponent("model-just-parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        // Simulate the rename keeping an ancient mtime…
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120 * 86_400)], ofItemAtPath: parked.path
        )
        // …and the park path stamping it.
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parked.path)
        WhisperEngine.pruneModelRecovery(at: root, now: now)
        #expect(FileManager.default.fileExists(atPath: parked.path))
    }

    @Test("Pruning a missing recovery folder is a no-op")
    func recoveryPruningMissingFolder() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-recovery-missing-\(UUID().uuidString)")
        WhisperEngine.pruneModelRecovery(at: missing, now: Date())
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
