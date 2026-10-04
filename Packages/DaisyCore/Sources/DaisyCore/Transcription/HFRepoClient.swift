//
//  HFRepoClient.swift
//  DaisyCore
//
//  Thin, dependency-injectable client for HuggingFace's public repo-tree
//  API — just enough to build our OWN download manifest. Deliberately
//  independent of FluidAudio's own (non-public) `HFTreeLister`/
//  `ModelHub`: per backlog B-2, once we own the transfer we don't call
//  FluidAudio's downloader again, and the raw HF REST API is a more
//  stable thing to depend on than another package's internal type.
//
//  Two endpoints, both plain HTTPS, no auth needed for a public repo:
//    GET {base}/api/models/{repo}/tree/main[/{path}]
//        → JSON array of {path, type: "directory"|"file", size},
//          paginated via a standard `Link: <url>; rel="next"` header.
//    GET {base}/{repo}/resolve/main/{path}
//        → the file's bytes (supports HTTP Range — what lets a
//          background URLSession resume a dropped transfer).
//
//  `manifest(repo:requiredTopLevel:)` walks the WHOLE repo tree once,
//  starting at the root, but only recurses into / includes entries whose
//  ROOT path component is in `requiredTopLevel` — the exact same
//  required-file-name set FluidAudio's own loader checks
//  (`ModelNames.ASR.requiredModelsV3()`, public), so what we download is
//  provably the same set FluidAudio would have downloaded, without us
//  hand-maintaining the internal file layout of each `.mlmodelc` bundle
//  (that comes straight from the tree listing).
//

import Foundation

public nonisolated struct ModelManifestEntry: Codable, Sendable, Equatable {
    /// Path relative to the repo root. IS the local relative path too:
    /// a compiled Core ML bundle's on-disk file tree mirrors the
    /// HuggingFace repo tree exactly, file for file.
    public let path: String
    public let size: Int64
    /// SHA-256 of the file's bytes, when the hub keeps it as an LFS object
    /// (every model weight does); nil for small files kept in git itself.
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public nonisolated enum HFRepoClient {
    public struct ClientError: Swift.Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// One fetch: given a URL, return its body and HTTP response. Real
    /// traffic goes through `session.data(for:)`; tests inject a fake to
    /// exercise pagination/filtering without a network.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    public static func fetch(session: URLSession) -> Fetch {
        { url in
            let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
            guard let http = response as? HTTPURLResponse else {
                throw ClientError("Non-HTTP response for \(url.absoluteString)")
            }
            return (data, http)
        }
    }

    /// Recursively list every file under `repo` whose ROOT path
    /// component is in `requiredTopLevel` — a directory (a `.mlmodelc`
    /// bundle) recurses fully; a bare file (`parakeet_vocab.json`) is
    /// included as-is. Depth-first, following pagination.
    public static func manifest(
        repo: String,
        requiredTopLevel: Set<String>,
        baseURL: String = "https://huggingface.co",
        fetch: Fetch? = nil
    ) async throws -> [ModelManifestEntry] {
        let resolvedFetch = fetch ?? Self.fetch(session: .shared)
        return try await listTree(
            repo: repo, path: "", baseURL: baseURL, fetch: resolvedFetch,
            include: { itemPath, _ in
                requiredTopLevel.contains { itemPath == $0 || itemPath.hasPrefix($0 + "/") }
            }
        )
    }

    static func listTree(
        repo: String,
        path: String,
        baseURL: String,
        fetch: Fetch,
        include: (_ path: String, _ isDirectory: Bool) -> Bool
    ) async throws -> [ModelManifestEntry] {
        var files: [ModelManifestEntry] = []
        let apiPath = path.isEmpty ? "" : "/\(path)"
        guard var url = URL(string: "\(baseURL)/api/models/\(repo)/tree/main\(apiPath)") else {
            throw ClientError("Bad HF tree URL for \(repo)/\(path)")
        }
        var visited = Set<URL>()

        while true {
            guard visited.insert(url).inserted else { break }
            let (data, response) = try await fetch(url)
            guard (200..<300).contains(response.statusCode) else {
                throw ClientError("HF tree listing failed for \(repo)/\(path): HTTP \(response.statusCode)")
            }
            guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ClientError("HF tree listing returned unexpected JSON for \(repo)/\(path)")
            }
            for item in items {
                guard let itemPath = item["path"] as? String, let type = item["type"] as? String else { continue }
                let isDirectory = type == "directory"
                guard include(itemPath, isDirectory) else { continue }
                if isDirectory {
                    files += try await listTree(
                        repo: repo, path: itemPath, baseURL: baseURL, fetch: fetch, include: include
                    )
                } else {
                    let size = (item["size"] as? NSNumber)?.int64Value ?? 0
                    // `lfs.oid` is the SHA-256 of the content — what the
                    // download is checked against (audit 02.10: size alone
                    // accepts a same-size substitution).
                    let oid = (item["lfs"] as? [String: Any])?["oid"] as? String
                    files.append(ModelManifestEntry(path: itemPath, size: size, sha256: oid))
                }
            }
            guard let next = nextPageURL(from: response) else { break }
            url = next
        }
        return files
    }

    /// HF paginates directory listings via a standard
    /// `Link: <url>; rel="next"` header (RFC 8288).
    static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.components(separatedBy: ",") {
            let segments = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments[1...].contains(where: { $0 == "rel=\"next\"" || $0 == "rel=next" }) else { continue }
            var raw = segments[0]
            if raw.hasPrefix("<") { raw.removeFirst() }
            if raw.hasSuffix(">") { raw.removeLast() }
            return URL(string: raw)
        }
        return nil
    }

    /// Where to `GET` one manifest entry's bytes.
    public static func downloadURL(repo: String, path: String, baseURL: String = "https://huggingface.co") -> URL? {
        URL(string: "\(baseURL)/\(repo)/resolve/main/\(path)")
    }
}
