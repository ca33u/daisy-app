//
//  HFRepoClientTests.swift
//  DaisyCoreTests
//
//  Offline: a fake `Fetch` serves canned tree pages, so this proves the
//  walk/filter/pagination logic without touching the network. The real
//  HF endpoint is exercised separately, by hand, from the simulator
//  (backlog B-2's [железо]-adjacent DoD — background sessions aren't
//  meaningfully testable on the Mac host at all).
//

import Testing
import Foundation
@testable import DaisyCore

/// Tiny mutable box so fetch closures (`@Sendable`) can record calls
/// without tripping Swift 6's actor-isolation checks — the tests
/// await every call in order, so there is no real race to guard
/// against, just the type system.
private nonisolated final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("HFRepoClient manifest walk")
struct HFRepoClientTests {
    private nonisolated static func page(_ items: [(String, String, Int?)], next: String? = nil) -> (Data, HTTPURLResponse) {
        let json = items.map { path, type, size -> [String: Any] in
            var d: [String: Any] = ["path": path, "type": type]
            if let size { d["size"] = size }
            return d
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        var headers: [String: String] = [:]
        if let next { headers["Link"] = "<\(next)>; rel=\"next\"" }
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test")!, statusCode: 200,
            httpVersion: nil, headerFields: headers
        )!
        return (data, response)
    }

    @Test func recursesIntoRequiredDirectoriesAndIncludesBareFiles() async throws {
        let calls = Box<[URL]>([])
        let fetch: HFRepoClient.Fetch = { url in
            calls.value.append(url)
            switch url.path {
            case "/api/models/org/repo/tree/main":
                return Self.page([
                    ("Preprocessor.mlmodelc", "directory", nil),
                    ("Skip.mlmodelc", "directory", nil),      // not required — must not recurse
                    ("parakeet_vocab.json", "file", 1234),
                    ("README.md", "file", 99),                 // not required — excluded
                ])
            case "/api/models/org/repo/tree/main/Preprocessor.mlmodelc":
                return Self.page([
                    ("Preprocessor.mlmodelc/coremldata.bin", "file", 500),
                    ("Preprocessor.mlmodelc/model.mil", "file", 2000),
                ])
            default:
                Issue.record("unexpected fetch: \(url)")
                return Self.page([])
            }
        }
        let manifest = try await HFRepoClient.manifest(
            repo: "org/repo",
            requiredTopLevel: ["Preprocessor.mlmodelc", "parakeet_vocab.json"],
            fetch: fetch
        )
        let paths = Set(manifest.map(\.path))
        #expect(paths == ["Preprocessor.mlmodelc/coremldata.bin", "Preprocessor.mlmodelc/model.mil", "parakeet_vocab.json"])
        #expect(manifest.first { $0.path == "parakeet_vocab.json" }?.size == 1234)
        #expect(!calls.value.contains { $0.path.contains("Skip.mlmodelc") })
    }

    @Test func followsPaginationCursorWithinOneDirectory() async throws {
        let pageCount = Box(0)
        let fetch: HFRepoClient.Fetch = { url in
            pageCount.value += 1
            if url.absoluteString.contains("cursor=2") {
                return Self.page([("Decoder.mlmodelc/b.bin", "file", 20)])
            }
            return Self.page(
                [("Decoder.mlmodelc/a.bin", "file", 10)],
                next: "https://huggingface.co/api/models/org/repo/tree/main/Decoder.mlmodelc?cursor=2"
            )
        }
        let manifest = try await HFRepoClient.manifest(repo: "org/repo", requiredTopLevel: ["Decoder.mlmodelc"], fetch: fetch)
        #expect(Set(manifest.map(\.path)) == ["Decoder.mlmodelc/a.bin", "Decoder.mlmodelc/b.bin"])
        #expect(pageCount.value == 2)
    }

    @Test func repeatingCursorStopsInsteadOfLoopingForever() async throws {
        // The repo root points to one required directory; that
        // directory's OWN listing endpoint misbehaves and echoes back
        // the cursor it was just given, forever. The walk must still
        // terminate — with the one real item, not a duplicate per loop.
        let selfURL = "https://huggingface.co/api/models/org/repo/tree/main/Decoder.mlmodelc"
        let fetch: HFRepoClient.Fetch = { url in
            if url.absoluteString == selfURL {
                return Self.page([("Decoder.mlmodelc/a.bin", "file", 10)], next: selfURL)
            }
            return Self.page([("Decoder.mlmodelc", "directory", nil)])
        }
        let manifest = try await HFRepoClient.manifest(repo: "org/repo", requiredTopLevel: ["Decoder.mlmodelc"], fetch: fetch)
        #expect(manifest.count == 1)   // the repeated cursor breaks the loop, not a duplicate per pass
    }

    @Test func nonOKStatusThrows() async throws {
        let fetch: HFRepoClient.Fetch = { url in
            (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: (any Error).self) {
            _ = try await HFRepoClient.manifest(repo: "org/repo", requiredTopLevel: ["X"], fetch: fetch)
        }
    }

    @Test func downloadURLShape() {
        #expect(
            HFRepoClient.downloadURL(repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", path: "Preprocessor.mlmodelc/coremldata.bin")?.absoluteString
            == "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/Preprocessor.mlmodelc/coremldata.bin"
        )
    }
}
