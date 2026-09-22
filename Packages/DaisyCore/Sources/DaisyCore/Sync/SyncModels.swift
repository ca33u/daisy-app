//
//  SyncModels.swift
//  DaisyCore
//
//  backlog 9 Ф3-A: what travels between a phone and a Mac, and what each
//  side remembers about the last exchange. Transport-neutral — the
//  CloudKit mapping lives in `CloudKitTransport`, the tests use an
//  in-memory one.
//
//  What travels (session-format.md §2 + backlog 9 "what to sync"):
//  the frontmatter as raw `key: value` lines, each with the stamp of
//  its last change; the body with its stamp; the small sidecars and
//  screenshots as files with stamps. Never audio, never `.recording`,
//  never `.send_failures.json`, never a staging folder.
//

import Foundation

public nonisolated struct SyncFile: Sendable, Equatable, Codable {
    public var data: Data
    /// Seconds since 1970 of the last change on the device that made it.
    public var stamp: Double
    public init(data: Data, stamp: Double) {
        self.data = data
        self.stamp = stamp
    }
}

/// One session as the other side sees it.
public nonisolated struct SessionSyncRecord: Sendable, Equatable, Codable {
    public var id: String
    /// Raw frontmatter values by key, exactly as written (quotes kept).
    public var frontmatter: [String: String]
    public var frontmatterStamps: [String: Double]
    /// Body after the closing `---`.
    public var body: String
    public var bodyStamp: Double
    /// Relative path → file (`summary.json`, `markers.json`,
    /// `screenshots/001.jpg`, …).
    public var files: [String: SyncFile]
    /// Which device last wrote this record (for the conflict copy's name).
    public var editor: String

    public init(id: String, frontmatter: [String: String] = [:], frontmatterStamps: [String: Double] = [:],
                body: String = "", bodyStamp: Double = 0, files: [String: SyncFile] = [:], editor: String = "") {
        self.id = id
        self.frontmatter = frontmatter
        self.frontmatterStamps = frontmatterStamps
        self.body = body
        self.bodyStamp = bodyStamp
        self.files = files
        self.editor = editor
    }
}

/// What this device remembers about a session after the last sync —
/// the base for the three-way merge.
public nonisolated struct SessionSyncMemory: Sendable, Equatable, Codable {
    public var frontmatter: [String: String] = [:]
    public var bodyHash: String = ""
    /// Path → stamp of the file as last synced.
    public var fileStamps: [String: Double] = [:]
    /// The local `transcript.md` as last seen: mtime + size, to skip
    /// re-reading unchanged sessions.
    public var transcriptMtime: Double = 0
    public var transcriptSize: Int = 0
    public init() {}
}

/// Persisted next to the sessions (`sync-state.json` in Application
/// Support). Never inside a session folder.
public nonisolated struct SyncState: Sendable, Equatable, Codable {
    public var deviceID: String
    /// Opaque server change token, serialized by the transport.
    public var changeToken: Data?
    public var sessions: [String: SessionSyncMemory] = [:]
    public var lastSyncAt: Date?
    /// Ids the person deleted HERE, not yet told to the server. The only
    /// source of a remote deletion — never "the folder is not there".
    public var pendingDeletes: [String] = []
    /// Ids deleted ELSEWHERE, with when we learned it: the local copy sat
    /// in `.daisy-trash/` and must not be pushed back as new — unless
    /// the person touches it after this date, which is a revival.
    public var tombstones: [String: Date] = [:]

    public init(deviceID: String = UUID().uuidString) {
        self.deviceID = deviceID
    }

    public static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Files that travel with a session, by relative path. Everything else
/// in the folder stays home.
public nonisolated enum SyncPolicy {
    public static let transcriptName = "transcript.md"
    /// Small sidecars: always.
    public static let sidecars: Set<String> = [
        "summary.json", "markers.json", "speakers.json", "speaker_suggestions.json",
        "import.json", "meeting-preparation.json", "plan-analysis.json", "plan-analysis-error.json",
        "transcript.raw.md",
    ]
    public static let screenshotsDirectory = "screenshots"
    /// Total bytes of screenshots per session that travel; above it the
    /// largest frames stay home (the index still travels).
    public static let screenshotBudget: Int = 20 * 1_048_576
    /// Never: audio, the recording marker, delivery state, staging.
    public static let neverPrefixes: [String] = [".recording", ".send_failures", ".daisy-"]

    public static func isSyncableFile(_ relativePath: String) -> Bool {
        if relativePath == transcriptName { return false }   // handled as frontmatter + body
        if sidecars.contains(relativePath) { return true }
        if relativePath.hasPrefix(screenshotsDirectory + "/") {
            let name = String(relativePath.dropFirst(screenshotsDirectory.count + 1))
            if name.hasPrefix(".") || name.contains("/") { return false }
            return name == "index.json" || name == "highlights.json" || ScreenshotIndex.number(of: URL(fileURLWithPath: name)) != nil
        }
        return false
    }
}
