//
//  LocalSummaryModelTests.swift
//  DaisyTests
//
//  «Локальная модель Daisy», Л-2: its files come from the bundled manifest,
//  land in Application Support, are checked by size for readiness, need room
//  before anything is fetched, resume where a download stopped, and go away
//  when deleted. No real 3 GB here: a small catalog of the same files.
//

import CryptoKit
import Foundation
import Testing
@testable import Daisy

// The model only downloads where MLX runs (Apple silicon, not Rosetta).
@Suite(.enabled(if: DaisyLLMClient.runsOnThisMac))
struct LocalSummaryModelTests {
    private static func file(_ path: String, _ data: Data) -> MacModelHosting.File {
        MacModelHosting.File(
            repo: LocalSummaryModel.repo, revision: String(repeating: "e", count: 40), path: path,
            size: Int64(data.count), runtime: true,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// The six files with small contents of their own.
    private static let contents = Dictionary(uniqueKeysWithValues: LocalSummaryModel.files.map { ($0, Data("bytes of \($0)".utf8)) })
    private static let catalog = LocalSummaryModel.files.map { file($0, contents[$0]!) }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local-model-\(UUID().uuidString)", isDirectory: true)
    }

    /// Hands back each file's right bytes and records what was asked.
    private func fetch(_ asked: FetchLog) -> MacModelHosting.Fetch {
        { url, _ in
            asked.add(url.lastPathComponent)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Self.contents[url.lastPathComponent, default: Data()].write(to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func theBundledManifestHasTheModelTheHelperLoads() throws {
        let entries = try LocalSummaryModel.entries()
        #expect(Set(entries.map(\.localPath)) == Set(LocalSummaryModel.files))
        #expect(entries.allSatisfy { $0.file.revision == "32f3e8ecf65426fc3306969496342d504bfa13f3" })
        let weights = try #require(entries.first { $0.localPath == "model.safetensors" })
        #expect(weights.file.size == 3_034_300_695)
        // «Скачать · 3,1 ГБ», and room for the files, their checked copies and a margin.
        let bytes = try #require(LocalSummaryModel.downloadBytes())
        #expect((3_000_000_000...3_100_000_000).contains(bytes))
        #expect(LocalSummaryModel.requiredFreeBytes() > 2 * bytes)
    }

    @Test func itLivesInApplicationSupportNotACache() throws {
        let path = try #require(LocalSummaryModel.directory).path
        #expect(path.hasSuffix("/Library/Application Support/Daisy/Models/llm/mlx-community/Qwen3.5-4B-MLX-4bit"))
        #expect(MacModelHosting.destination(for: .summaryLLM) == LocalSummaryModel.directory)
    }

    @Test func readinessIsEveryFileAtItsSize() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LocalSummaryModel.state(in: dir, catalog: Self.catalog) == .notInstalled)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.contents["config.json"]!.write(to: dir.appendingPathComponent("config.json"))
        guard case .partial(let bytes, let total) = LocalSummaryModel.state(in: dir, catalog: Self.catalog) else {
            Issue.record("one file of six isn't partial")
            return
        }
        #expect(bytes == Int64(Self.contents["config.json"]!.count))
        #expect(total == Self.catalog.reduce(0) { $0 + $1.size })

        for path in LocalSummaryModel.files {
            try Self.contents[path]!.write(to: dir.appendingPathComponent(path))
        }
        #expect(LocalSummaryModel.state(in: dir, catalog: Self.catalog) == .installed)
        // A truncated weights file isn't a model.
        try Data("short".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        #expect(LocalSummaryModel.state(in: dir, catalog: Self.catalog) != .installed)
    }

    @Test func withoutRoomNothingIsFetched() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = FetchLog()
        let required = LocalSummaryModel.requiredFreeBytes(catalog: Self.catalog)
        await #expect(throws: LocalSummaryModel.Failure.notEnoughSpace(required: required, available: 1_000)) {
            try await LocalSummaryModel.download(into: dir, freeBytes: 1_000, catalog: Self.catalog, fetch: fetch(asked))
        }
        #expect(asked.names.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aDownloadGoesOnWhereItStopped() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Two files made it last time.
        for path in ["config.json", "tokenizer.json"] {
            try Self.contents[path]!.write(to: dir.appendingPathComponent(path))
        }
        let asked = FetchLog()
        let shares = Shares()

        try await LocalSummaryModel.download(
            into: dir, freeBytes: .max, catalog: Self.catalog, fetch: fetch(asked), progress: { shares.add($0) })

        #expect(Set(asked.names) == Set(LocalSummaryModel.files).subtracting(["config.json", "tokenizer.json"]))
        #expect(LocalSummaryModel.state(in: dir, catalog: Self.catalog) == .installed)
        #expect(shares.last == 1)
    }

    @Test func deletingRemovesTheModel() async throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("config.json"))
        try await LocalSummaryModel.delete(at: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Nothing there: nothing to do.
        try await LocalSummaryModel.delete(at: dir)
    }

    /// A delete during a download stops it first; the download doesn't put
    /// the folder back.
    @Test func deletingDuringADownloadStopsIt() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = FetchLog()
        // Every fetch waits until cancelled.
        let slow: MacModelHosting.Fetch = { url, _ in
            started.add(url.lastPathComponent)
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        // A file from an earlier run, so there is a folder to remove.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.contents["config.json"]!.write(to: dir.appendingPathComponent("config.json"))
        let download = Task {
            try await LocalSummaryModel.download(into: dir, freeBytes: .max, catalog: Self.catalog, fetch: slow)
        }
        #expect(await eventually { !started.names.isEmpty })

        try await LocalSummaryModel.delete(at: dir)

        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// One download per folder: a second is refused, and the first goes on.
    @Test func aSecondDownloadIsRefusedWhileOneRuns() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = FetchLog()
        let fetcher = fetch(asked)
        let slow: MacModelHosting.Fetch = { url, written in
            try await Task.sleep(for: .milliseconds(50))
            return try await fetcher(url, written)
        }
        let first = Task {
            try await LocalSummaryModel.download(into: dir, freeBytes: .max, catalog: Self.catalog, fetch: slow)
        }
        #expect(await eventually { !asked.names.isEmpty })

        await #expect(throws: LocalSummaryModel.Failure.busy) {
            try await LocalSummaryModel.download(into: dir, freeBytes: .max, catalog: Self.catalog, fetch: slow)
        }

        try await first.value
        #expect(asked.names.sorted() == LocalSummaryModel.files.sorted())
        // Done: the folder is free for the next one.
        try await LocalSummaryModel.download(into: dir, freeBytes: .max, catalog: Self.catalog, fetch: slow)
        #expect(asked.names.count == LocalSummaryModel.files.count)
    }

    @Test func roomIsAskedForWhatIsStillMissing() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = LocalSummaryModel.requiredFreeBytes(in: dir, catalog: Self.catalog)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for path in LocalSummaryModel.files {
            try Self.contents[path]!.write(to: dir.appendingPathComponent(path))
        }
        #expect(LocalSummaryModel.requiredFreeBytes(in: dir, catalog: Self.catalog) == 0)
        #expect(whole > 0)
        // The real model, nothing on disk: its 3 GB, twice, and a margin.
        #expect(LocalSummaryModel.requiredFreeBytes() > 7_000_000_000)
    }

    @Test func noRoomReadsAsWords() {
        let words = LocalSummaryModel.Failure.notEnoughSpace(required: 7_200_000_000, available: 2_000_000_000).localizedDescription
        #expect(words.contains("6.7"))
    }
}

private func eventually(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ name: String) { lock.withLock { list.append(name) } }
    var names: [String] { lock.withLock { list } }
}

private final class Shares: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func add(_ share: Double) { lock.withLock { list.append(share) } }
    var last: Double? { lock.withLock { list.last } }
}
