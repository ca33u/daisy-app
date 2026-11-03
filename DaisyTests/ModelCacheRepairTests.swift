//
//  ModelCacheRepairTests.swift
//  DaisyTests
//
//  FluidAudio #1067: a model bundle a cut-short fetch left without some of
//  its files. FluidAudio 0.15.6 checks only that the bundle's folder is
//  there and, with downloads blocked, hands back the load's own error
//  rather than `DownloadError`, so the cache stayed broken. Now the set's
//  files are checked against the manifest, the broken ones fetched again,
//  and the model loaded once more.
//

import CryptoKit
import FluidAudio
import Foundation
import Testing
@testable import Daisy

@MainActor
struct ModelCacheRepairTests {
    private struct Broken: Error {}

    @Test func aBrokenCacheIsRepairedAndLoadedAgain() async throws {
        var loads = 0
        var repaired: [String] = []
        let value = try await FluidAudioNetworkGuard.loadRepairingCache(.diarizer, repair: { set, _ in
            repaired.append(set.name)
            return true
        }) {
            loads += 1
            if loads == 1 { throw Broken() }
            return 42
        }
        #expect(value == 42)
        #expect(loads == 2)
        #expect(repaired == ["speaker models"])
    }

    @Test func anIntactCacheKeepsTheLoadsOwnError() async {
        var loads = 0
        await #expect(throws: Broken.self) {
            try await FluidAudioNetworkGuard.loadRepairingCache(.parakeetV3, repair: { _, _ in false }) {
                loads += 1
                throw Broken()
            }
        }
        #expect(loads == 1)
    }

    @Test func nothingCachedAndCancellationAreNotRepairs() async {
        var repairs = 0
        let repair: (MacModelHosting.ModelSet, (@Sendable (Double) -> Void)?) async throws -> Bool = { _, _ in
            repairs += 1
            return true
        }
        await #expect(throws: DownloadError.self) {
            try await FluidAudioNetworkGuard.loadRepairingCache(.sileroVAD, repair: repair) {
                throw DownloadError.modelMissing(repo: "silero-vad", missing: ["x.mlmodelc"])
            }
        }
        await #expect(throws: CancellationError.self) {
            try await FluidAudioNetworkGuard.loadRepairingCache(.sileroVAD, repair: repair) {
                throw CancellationError()
            }
        }
        #expect(repairs == 0)
    }

    @Test func aSecondFailureAfterTheRepairIsTheErrorTheCallerSees() async {
        struct StillBroken: Error {}
        var loads = 0
        await #expect(throws: StillBroken.self) {
            try await FluidAudioNetworkGuard.loadRepairingCache(.diarizer, repair: { _, _ in true }) {
                loads += 1
                if loads == 1 { throw Broken() }
                throw StillBroken()
            }
        }
        #expect(loads == 2)
    }

    @Test func aCancelledLoadIsNotRepaired() async {
        let task = Task { @MainActor () -> Int in
            var repairs = 0
            _ = try? await FluidAudioNetworkGuard.loadRepairingCache(.diarizer, repair: { _, _ in
                repairs += 1
                return true
            }) { () -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                throw Broken()
            }
            return repairs
        }
        #expect(await task.value == 0)
    }

    @Test func aRepairThatCantFetchIsTheErrorTheCallerSees() async {
        await #expect(throws: URLError.self) {
            try await FluidAudioNetworkGuard.loadRepairingCache(.diarizer, repair: { _, _ in
                throw URLError(.notConnectedToInternet)
            }) {
                throw Broken()
            }
        }
    }

    /// `repairAfterFailedLoad` itself: only the broken file is fetched and
    /// progress covers only it; an intact folder is no repair, and is
    /// checked again once a file in it changes.
    @Test func theRepairFetchesOnlyWhatsBroken() async throws {
        func file(_ path: String, _ bytes: Data) -> MacModelHosting.File {
            MacModelHosting.File(repo: "FluidInference/silero-vad-coreml", revision: String(repeating: "e", count: 40),
                                 path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/" + path, size: Int64(bytes.count),
                                 runtime: true, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        let weights = Data(repeating: 7, count: 4096), header = Data("coreml header".utf8)
        let catalog = [file("weights/weight.bin", weights), file("coremldata.bin", header)]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let weightsAt = dir.appendingPathComponent(catalog[0].path)
        try FileManager.default.createDirectory(at: weightsAt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.write(to: weightsAt)

        let asked = Paths(), fractions = Fractions()
        let fetch: MacModelHosting.Fetch = { url, _ in
            asked.add(url.lastPathComponent)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try (url.lastPathComponent == "coremldata.bin" ? header : weights).write(to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await MacModelHosting.repairAfterFailedLoad(.sileroVAD, in: dir, progress: { fractions.add($0) },
                                                                fetch: fetch, catalog: catalog))
        #expect(asked.list == ["coremldata.bin"])
        #expect(try Data(contentsOf: dir.appendingPathComponent(catalog[1].path)) == header)
        #expect(fractions.list.last == 1)
        #expect(fractions.list.allSatisfy { $0 >= 0 && $0 <= 1 })

        // Now intact: no repair, nothing fetched, twice.
        #expect(try await !MacModelHosting.repairAfterFailedLoad(.sileroVAD, in: dir, fetch: fetch, catalog: catalog))
        #expect(try await !MacModelHosting.repairAfterFailedLoad(.sileroVAD, in: dir, fetch: fetch, catalog: catalog))
        #expect(asked.list == ["coremldata.bin"])

        // A file cut short after that is seen and fetched again.
        try Data("x".utf8).write(to: weightsAt)
        #expect(try await MacModelHosting.repairAfterFailedLoad(.sileroVAD, in: dir, fetch: fetch, catalog: catalog))
        #expect(asked.list == ["coremldata.bin", "weight.bin"])
        #expect(try Data(contentsOf: weightsAt) == weights)

        // A set the catalog doesn't have is no repair either.
        #expect(try await !MacModelHosting.repairAfterFailedLoad(.diarizer, in: dir, fetch: fetch, catalog: catalog))
    }

    /// The person's speaker models, read only: the test copies them.
    private nonisolated static let installedDiarizer = DiarizerModels.defaultModelsDirectory()

    /// Runs where the speaker models are installed and are the pinned copy.
    private nonisolated static var installedDiarizerIsPinned: Bool {
        guard let files = try? MacModelHosting.catalog(),
              let entries = try? MacModelHosting.entries(for: .diarizer, in: files) else { return false }
        return entries.allSatisfy { MacModelHosting.valid($0.file, at: installedDiarizer.appendingPathComponent($0.localPath)) }
    }

    /// The real library on a real half bundle: a copy of the speaker models
    /// without one bundle's `coremldata.bin` doesn't load, the error isn't
    /// an offline rejection, and fetching just that file makes it load.
    @Test(.enabled(if: installedDiarizerIsPinned, "needs the pinned speaker models installed"))
    func aHalfDownloadedDiarizerBundleLoadsAfterTheRepair() async throws {
        // Offline, or FluidAudio would delete the copy and go to Hugging Face.
        FluidAudioNetworkGuard.engage()
        try #require(ModelHub.offlineMode)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cache-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent(Self.installedDiarizer.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: Self.installedDiarizer, to: dir)
        let cut = "pyannote_segmentation.mlmodelc/coremldata.bin"
        try fm.removeItem(at: dir.appendingPathComponent(cut))

        do {
            _ = try await DiarizerModels.load(from: dir)
            Issue.record("a bundle without its coremldata.bin loaded")
        } catch {
            #expect(!FluidAudioNetworkGuard.isOfflineRejection(error))
        }

        let asked = Paths()
        let installed = Self.installedDiarizer
        let fetch: MacModelHosting.Fetch = { url, _ in
            // …/resolve/main/<path>: served from the installed copy.
            let path = url.path().components(separatedBy: "/resolve/main/").last ?? ""
            asked.add(path)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: installed.appendingPathComponent(path), to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let catalog = try MacModelHosting.catalog()
        _ = try await FluidAudioNetworkGuard.loadRepairingCache(.diarizer, repair: { set, progress in
            try await MacModelHosting.repairAfterFailedLoad(set, in: dir, progress: progress, fetch: fetch, catalog: catalog)
        }) {
            try await DiarizerModels.load(from: dir)
        }
        #expect(asked.list == [cut])
    }
}

private final class Paths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    var list: [String] { lock.withLock { paths } }
}

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var list: [Double] { lock.withLock { values } }
}
