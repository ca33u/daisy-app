//
//  MacModelHostingTests.swift
//  DaisyTests
//
//  Backlog 31: the Mac's models from our mirror first, then pinned Hugging
//  Face, every file checked against the bundled manifest.
//

import CryptoKit
import Foundation
import Testing
@testable import Daisy

struct MacModelHostingTests {
    private func manifest() throws -> [MacModelHosting.File] {
        // The app's own bundle carries it; the test host is the app.
        try MacModelHosting.catalog()
    }

    @Test func theBundledManifestCoversEveryMacModel() throws {
        let files = try manifest()
        for variant in ["large-v3-v20240930_626MB", "large-v3-v20240930"] {
            let entries = try MacModelHosting.entries(for: .whisper(variant: variant), in: files)
            #expect(entries.contains { $0.localPath == "openai_whisper-\(variant)/AudioEncoder.mlmodelc/weights/weight.bin" })
            // The tokenizer goes inside the variant folder.
            #expect(entries.contains { $0.localPath == "openai_whisper-\(variant)/tokenizer.json" })
            // …and the other variant's files don't come along.
            let other = variant.hasSuffix("_626MB") ? "large-v3-v20240930/" : "large-v3-v20240930_626MB/"
            #expect(!entries.contains { $0.localPath.hasPrefix("openai_whisper-" + other) })
        }
        let parakeet = try MacModelHosting.entries(for: .parakeetV3, in: files)
        for root in ["Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/"] {
            #expect(parakeet.contains { $0.localPath.hasPrefix(root) && $0.localPath.hasSuffix("coremldata.bin") })
        }
        #expect(parakeet.contains { $0.localPath == "parakeet_vocab.json" })
        #expect(!parakeet.contains { $0.localPath.hasPrefix("Encoder_v2.mlmodelc/") })
        #expect(try MacModelHosting.entries(for: .sileroVAD, in: files)
            .allSatisfy { $0.localPath.hasPrefix("silero-vad-unified-256ms-v6.2.1.mlmodelc/") })
        let speakers = try MacModelHosting.entries(for: .diarizer, in: files)
        #expect(speakers.contains { $0.localPath.hasPrefix("pyannote_segmentation.mlmodelc/") })
        #expect(speakers.contains { $0.localPath.hasPrefix("wespeaker_v2.mlmodelc/") })
    }

    @Test func everyFileHasAPlaceOfItsOwn() throws {
        let files = try manifest()
        for set: MacModelHosting.ModelSet in [.whisper(variant: "large-v3-v20240930_626MB"), .whisper(variant: "large-v3-v20240930"),
                                              .parakeetV3, .sileroVAD, .diarizer] {
            let paths = try MacModelHosting.entries(for: set, in: files).map(\.localPath)
            #expect(Set(paths).count == paths.count, "\(set.name)")
        }
    }

    @Test func aVariantNotInTheManifestIsTheLibrarysToFetch() throws {
        #expect(throws: MacModelHosting.Failure.self) {
            try MacModelHosting.entries(for: .whisper(variant: "tiny"), in: try manifest())
        }
    }

    @Test func urlsAreTheMirrorsMainOrThePinnedCommit() throws {
        let file = MacModelHosting.File(repo: "FluidInference/silero-vad-coreml", revision: String(repeating: "a", count: 40),
                                        path: "x.mlmodelc/coremldata.bin", size: 1, runtime: true,
                                        sha256: String(repeating: "b", count: 64))
        #expect(try MacModelHosting.url(for: file, source: .mirror).absoluteString
                == "https://models.mydaisy.io/FluidInference/silero-vad-coreml/resolve/main/x.mlmodelc/coremldata.bin")
        #expect(try MacModelHosting.url(for: file, source: .huggingFace).absoluteString
                == "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/\(String(repeating: "a", count: 40))/x.mlmodelc/coremldata.bin")
    }

    @Test func aBadCatalogIsRefused() {
        let bad = #"{"schemaVersion":1,"files":[{"repo":"a/b","revision":"x","path":"../etc","size":1,"runtime":true,"sha256":"y"}]}"#
        #expect(throws: (any Error).self) { try MacModelHosting.decodeCatalog(Data(bad.utf8)) }
        #expect(!MacModelHosting.safePath("a/../b"))
        #expect(MacModelHosting.safePath("Encoder.mlmodelc/weights/weight.bin"))
    }

    @Test func wrongBytesFromTheMirrorFallToPinnedHuggingFace() async throws {
        let good = Data("the real model bytes".utf8)
        let sha = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
        let file = MacModelHosting.File(repo: "FluidInference/silero-vad-coreml", revision: String(repeating: "c", count: 40),
                                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin",
                                        size: Int64(good.count), runtime: true, sha256: sha)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Asked()
        let fetch: MacModelHosting.Fetch = { url, _ in
            asked.add(url.host() ?? "")
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            // The mirror hands back a corrupted file; Hugging Face the right one.
            try (url.host() == "models.mydaisy.io" ? Data("tampered!!".utf8) : good).write(to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await MacModelHosting.prefetch(.sileroVAD, into: dir, fetch: fetch, catalog: [file])
        let placed = dir.appendingPathComponent(file.path)
        #expect(try Data(contentsOf: placed) == good)
        #expect(asked.hosts == ["models.mydaisy.io", "huggingface.co"])

        // Intact on disk: nothing is fetched again.
        try await MacModelHosting.prefetch(.sileroVAD, into: dir, fetch: fetch, catalog: [file])
        #expect(asked.hosts.count == 2)
    }

    @Test func bothHostsWrongMeansNoFileInPlace() async throws {
        let file = MacModelHosting.File(repo: "FluidInference/silero-vad-coreml", revision: String(repeating: "d", count: 40),
                                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin",
                                        size: 5, runtime: true, sha256: String(repeating: "0", count: 64))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fetch: MacModelHosting.Fetch = { url, _ in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("wrong".utf8).write(to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: (any Error).self) {
            try await MacModelHosting.prefetch(.sileroVAD, into: dir, fetch: fetch, catalog: [file])
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(file.path).path))
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ host: String) { lock.withLock { list.append(host) } }
    var hosts: [String] { lock.withLock { list } }
}
