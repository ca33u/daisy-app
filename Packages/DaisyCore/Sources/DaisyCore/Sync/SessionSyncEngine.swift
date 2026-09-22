//
//  SessionSyncEngine.swift
//  DaisyCore
//
//  backlog 9 Ф3-A: text goes both ways. One engine, one code path, on the
//  phone and on the Mac; the transport is the only thing that differs.
//
//  A sync is two halves. PULL: fetch what changed on the server since
//  the token, and for each session merge it into the local folder —
//  frontmatter by key, body by last write (loser kept beside the file),
//  files by stamp. PUSH: scan the local folders, and for every session
//  whose transcript or files moved since the last sync, send the whole
//  record. What this device merged and won goes out in the same pass.
//
//  Rules that must not bend:
//  • a folder still recording (`.recording` present) or without
//    `transcript.md` has nothing to sync and is skipped;
//  • a deletion travels ONLY as an explicit tombstone from the person's
//    "delete" (`markDeleted`); a folder that is merely not there — moved
//    by hand, evicted, on a detached disk — sends nothing (backlog 9:
//    the August audit, where a deletion inferred from a missing file
//    destroyed the only copy);
//  • the engine never deletes a local folder: an explicit tombstone from
//    the other device moves the local copy into the hidden
//    `.daisy-trash/<id>/` beside the sessions (recoverable, invisible to
//    the Library) and remembers the tombstone so the copy is not pushed
//    back as new; editing it after that is a revival and it travels again;
//  • writes are atomic and touch only the parts that changed (§7.2/§7.3);
//  • audio never travels.
//

import Foundation
import os

@MainActor
public final class SessionSyncEngine {
    public let base: SessionsBase
    public let stateURL: URL
    public private(set) var state: SyncState
    private let transport: any SyncTransport
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Sync")
    /// Called with the ids whose local files changed during a pull.
    public var onLocalChanged: (([String]) -> Void)?

    public struct Summary: Sendable, Equatable {
        public var pulled: Int = 0
        public var pushed: Int = 0
        public var conflicts: Int = 0
        public var deletedRemotely: Int = 0
        public init() {}
        /// Nothing moved in either direction.
        public var isEmpty: Bool { self == Summary() }
    }

    public init(base: SessionsBase, stateURL: URL, transport: any SyncTransport) {
        self.base = base
        self.stateURL = stateURL
        self.transport = transport
        self.state = SyncState.load(from: stateURL)
    }

    /// Pull, then push. Idempotent; safe to call often.
    @discardableResult
    public func syncOnce() async throws -> Summary {
        var summary = Summary()
        let changes = try await transport.fetchChanges(since: state.changeToken)
        var touched: [String] = []
        for record in changes.records {
            // Our own push echoed back: nothing the server has from this
            // device can be newer than this device — and applying it
            // would resurrect a folder deleted here on purpose.
            guard record.editor != state.deviceID else { continue }
            let outcome = try apply(record)
            if outcome.wroteLocally { touched.append(record.id); summary.pulled += 1 }
            if outcome.conflict { summary.conflicts += 1 }
        }
        for id in changes.deletedIDs where !state.pendingDeletes.contains(id) {
            // Someone deleted it on purpose over there. Ours goes to the
            // hidden trash, never to /dev/null.
            if trashLocalCopy(id) { summary.deletedRemotely += 1 }
            state.sessions[id] = nil
            state.tombstones[id] = Date()
            log.notice("Remote deleted \(id, privacy: .public); local copy moved to .daisy-trash")
        }
        state.changeToken = changes.token
        try state.save(to: stateURL)
        if !touched.isEmpty { onLocalChanged?(touched) }

        let outgoing = try scanForPush()
        if !outgoing.isEmpty {
            try await transport.push(outgoing)
            for record in outgoing { remember(record) }
            summary.pushed = outgoing.count
        }
        if !state.pendingDeletes.isEmpty {
            let ids = state.pendingDeletes
            try await transport.delete(ids)
            state.pendingDeletes.removeAll()
            for id in ids { state.sessions[id] = nil }
            log.notice("Told the server about \(ids.count, privacy: .public) deletion(s) made here")
        }
        state.lastSyncAt = Date()
        try state.save(to: stateURL)
        sweepTrash()
        return summary
    }

    /// J-0 "Delete my data from iCloud": everything on the server goes,
    /// and this device forgets what it synced — turning sync on again
    /// starts from scratch (a full push, nothing lost locally).
    public func eraseCloudData() async throws {
        try await transport.eraseEverything()
        let deviceID = state.deviceID
        state = SyncState(deviceID: deviceID)
        try state.save(to: stateURL)
    }

    /// The person deleted this session HERE. The folder is the caller's
    /// business (already gone or about to be); this is the only way a
    /// deletion reaches the server.
    public func markDeleted(_ id: String) {
        guard !state.pendingDeletes.contains(id) else { return }
        state.pendingDeletes.append(id)
        state.sessions[id] = nil
        state.tombstones[id] = nil
        try? state.save(to: stateURL)
    }

    public static let trashDirectoryName = ".daisy-trash"
    /// How long a copy deleted elsewhere stays recoverable here.
    public static let trashRetention: TimeInterval = 30 * 86_400

    /// Empty what has sat in the trash longer than `trashRetention`.
    /// Once per pass; a folder's age is the moment it was trashed.
    func sweepTrash(now: Date = Date()) {
        let fm = FileManager.default
        let trash = base.sessionsDirectory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        for item in items {
            let moved = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(moved) > Self.trashRetention {
                try? fm.removeItem(at: item)
                log.notice("Trash: removed \(item.lastPathComponent, privacy: .public) after \(Int(Self.trashRetention / 86_400), privacy: .public) days")
            }
        }
    }

    /// Move a local folder into the hidden trash; false when there was
    /// nothing to move. A name clash keeps both (suffix).
    private func trashLocalCopy(_ id: String) -> Bool {
        let fm = FileManager.default
        let source = base.sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return false }
        let trash = base.sessionsDirectory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        var target = trash.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            target = trash.appendingPathComponent("\(id)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        }
        do {
            try fm.moveItem(at: source, to: target)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return true
        } catch {
            log.error("Could not move \(id, privacy: .public) to trash: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Local snapshot

    /// The record a local session folder would send, or nil when it has
    /// nothing to sync.
    public func snapshot(of id: String) throws -> SessionSyncRecord? {
        let dir = base.sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.appendingPathComponent(SessionWriter.recordingMarkerName).path) else { return nil }
        let transcriptURL = dir.appendingPathComponent(SyncPolicy.transcriptName)
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
        let stamp = Self.mtime(of: transcriptURL)
        let (values, _) = Self.rawFrontmatter(text)
        var record = SessionSyncRecord(id: id, frontmatter: values, frontmatterStamps: values.mapValues { _ in stamp },
                                       body: SessionEditing.split(text).body, bodyStamp: stamp, editor: state.deviceID)
        var screenshotBytes = 0
        for path in Self.syncablePaths(in: dir) {
            let url = dir.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            if path.hasPrefix(SyncPolicy.screenshotsDirectory + "/"), ScreenshotIndex.number(of: url) != nil {
                if screenshotBytes + data.count > SyncPolicy.screenshotBudget { continue }
                screenshotBytes += data.count
            }
            record.files[path] = SyncFile(data: data, stamp: Self.mtime(of: url))
        }
        return record
    }

    /// Sessions whose transcript or files moved since the last sync.
    func scanForPush() throws -> [SessionSyncRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: base.sessionsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [SessionSyncRecord] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let id = dir.lastPathComponent
            guard !id.hasPrefix(".") else { continue }
            let transcriptURL = dir.appendingPathComponent(SyncPolicy.transcriptName)
            guard fm.fileExists(atPath: transcriptURL.path),
                  !fm.fileExists(atPath: dir.appendingPathComponent(SessionWriter.recordingMarkerName).path) else { continue }
            let memory = state.sessions[id]
            let mtime = Self.mtime(of: transcriptURL)
            let size = Self.size(of: transcriptURL)
            if let tombstone = state.tombstones[id] {
                // Deleted elsewhere on purpose: a copy that reappeared here
                // (restored from the trash, re-imported) stays put unless
                // the person touched it after the tombstone.
                guard Date(timeIntervalSince1970: mtime) > tombstone else { continue }
                state.tombstones[id] = nil
            }
            var changed = memory == nil || memory!.transcriptMtime != mtime || memory!.transcriptSize != size
            if !changed, let memory {
                let paths = Self.syncablePaths(in: dir)
                if Set(paths) != Set(memory.fileStamps.keys) { changed = true }
                else { changed = paths.contains { Self.mtime(of: dir.appendingPathComponent($0)) != memory.fileStamps[$0] } }
            }
            guard changed, var record = try snapshot(of: id) else { continue }
            // Keys/body unchanged since the last sync keep their old
            // stamp semantics: only what moved is stamped "now".
            if let memory {
                for (key, value) in record.frontmatter where memory.frontmatter[key] == value {
                    record.frontmatterStamps[key] = 0
                }
            }
            out.append(record)
        }
        return out
    }

    private func remember(_ record: SessionSyncRecord) {
        let dir = base.sessionsDirectory.appendingPathComponent(record.id, isDirectory: true)
        var memory = SessionSyncMemory()
        memory.frontmatter = record.frontmatter
        memory.bodyHash = FrontmatterMerge.hash(record.body)
        memory.fileStamps = record.files.mapValues(\.stamp)
        let transcriptURL = dir.appendingPathComponent(SyncPolicy.transcriptName)
        memory.transcriptMtime = Self.mtime(of: transcriptURL)
        memory.transcriptSize = Self.size(of: transcriptURL)
        state.sessions[record.id] = memory
    }

    // MARK: - Apply a remote record

    struct Outcome { var wroteLocally = false; var conflict = false }

    func apply(_ remote: SessionSyncRecord) throws -> Outcome {
        let fm = FileManager.default
        let dir = base.sessionsDirectory.appendingPathComponent(remote.id, isDirectory: true)
        let transcriptURL = dir.appendingPathComponent(SyncPolicy.transcriptName)
        var outcome = Outcome()

        // A session still recording here is never touched by the cloud.
        if fm.fileExists(atPath: dir.appendingPathComponent(SessionWriter.recordingMarkerName).path) { return outcome }

        if !fm.fileExists(atPath: transcriptURL.path) {
            // New here: write the whole record into a hidden staging
            // folder and move it into place (§7.3).
            let staging = base.sessionsDirectory.appendingPathComponent(".daisy-sync-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let text = Self.render(frontmatter: remote.frontmatter, order: nil, body: remote.body)
            try Data(text.utf8).write(to: staging.appendingPathComponent(SyncPolicy.transcriptName), options: .atomic)
            for (path, file) in remote.files {
                let url = staging.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url, options: .atomic)
            }
            if fm.fileExists(atPath: dir.path) {
                // Audio-only folder (an interrupted recording adopted
                // nowhere): move the files in beside it.
                for item in try fm.contentsOfDirectory(atPath: staging.path) {
                    try? fm.removeItem(at: dir.appendingPathComponent(item))
                    try fm.moveItem(at: staging.appendingPathComponent(item), to: dir.appendingPathComponent(item))
                }
                try? fm.removeItem(at: staging)
            } else {
                try fm.moveItem(at: staging, to: dir)
            }
            outcome.wroteLocally = true
            var memory = SessionSyncMemory()
            memory.frontmatter = remote.frontmatter
            memory.bodyHash = FrontmatterMerge.hash(remote.body)
            memory.fileStamps = remote.files.mapValues(\.stamp)
            memory.transcriptMtime = Self.mtime(of: transcriptURL)
            memory.transcriptSize = Self.size(of: transcriptURL)
            state.sessions[remote.id] = memory
            return outcome
        }

        // Three-way merge against what we synced last.
        let localText = try String(contentsOf: transcriptURL, encoding: .utf8)
        let localStamp = Self.mtime(of: transcriptURL)
        let (localValues, _) = Self.rawFrontmatter(localText)
        let localBody = SessionEditing.split(localText).body
        let memory = state.sessions[remote.id] ?? SessionSyncMemory()

        let fmResult = FrontmatterMerge.merge(
            base: memory.frontmatter,
            local: .init(values: localValues, stamp: localStamp),
            remote: .init(values: remote.frontmatter, stamps: remote.frontmatterStamps)
        )
        let bodyResult = FrontmatterMerge.mergeBody(
            baseHash: memory.bodyHash, local: localBody, localStamp: localStamp,
            remote: remote.body, remoteStamp: remote.bodyStamp
        )

        var text = localText
        for key in fmResult.changedLocally {
            if let value = fmResult.values[key] { text = SessionDocument.upsertFrontmatter(in: text, key: key, value: value) }
        }
        var newBodyHash = FrontmatterMerge.hash(localBody)
        if bodyResult.winner == .remote {
            if bodyResult.conflict {
                try Data(localText.utf8).write(to: Self.conflictURL(in: dir, editor: state.deviceID), options: .atomic)
                outcome.conflict = true
            }
            text = SessionEditing.replacingBody(of: text, with: remote.body)
            newBodyHash = FrontmatterMerge.hash(remote.body)
        } else if bodyResult.winner == .local, bodyResult.conflict {
            try Data(Self.render(frontmatter: remote.frontmatter, order: nil, body: remote.body).utf8)
                .write(to: Self.conflictURL(in: dir, editor: remote.editor), options: .atomic)
            outcome.conflict = true
        }
        if text != localText {
            try Data(text.utf8).write(to: transcriptURL, options: .atomic)
            outcome.wroteLocally = true
        }

        // Files: newer stamp wins; a file we never synced and don't have
        // is simply taken.
        var fileStamps = memory.fileStamps
        for (path, file) in remote.files {
            let url = dir.appendingPathComponent(path)
            let localStampForFile = fm.fileExists(atPath: url.path) ? Self.mtime(of: url) : 0
            let localChanged = localStampForFile != 0 && memory.fileStamps[path] != localStampForFile
            if !fm.fileExists(atPath: url.path) || !localChanged || file.stamp > localStampForFile {
                if (try? Data(contentsOf: url)) != file.data {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.data.write(to: url, options: .atomic)
                    outcome.wroteLocally = true
                }
                fileStamps[path] = Self.mtime(of: url)
            }
        }

        // Remember the merged state; whatever local kept goes out with
        // the next push because its stamps differ from this memory.
        var updated = memory
        updated.frontmatter = fmResult.values.filter { !fmResult.changedRemotely.contains($0.key) }
            .merging(remote.frontmatter) { local, _ in local }
        // Base = what both sides agree on after this merge: remote's
        // values for keys remote won, local's for keys local won are
        // NOT yet on the server — leave them out so the next scan sees
        // them as changed and pushes.
        updated.frontmatter = remote.frontmatter
        for key in fmResult.changedRemotely { updated.frontmatter[key] = nil }
        updated.bodyHash = bodyResult.winner == .local && bodyResult.conflict ? "" : newBodyHash
        if bodyResult.winner == .local, !bodyResult.conflict { updated.bodyHash = FrontmatterMerge.hash(remote.body) }
        updated.fileStamps = fileStamps
        updated.transcriptMtime = Self.mtime(of: transcriptURL)
        updated.transcriptSize = Self.size(of: transcriptURL)
        if outcome.wroteLocally || fmResult.changedRemotely.isEmpty && bodyResult.winner != .local {
            // Nothing local to push: the memory matches the file.
        } else {
            // Force the next scan to push by making the memory disagree.
            updated.transcriptMtime = 0
        }
        state.sessions[remote.id] = updated
        return outcome
    }

    // MARK: - Helpers

    static func conflictURL(in dir: URL, editor: String) -> URL {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("transcript.conflict-\(stamp).md")
    }

    /// `key` → raw value (quotes kept) and the key order.
    static func rawFrontmatter(_ text: String) -> ([String: String], [String]) {
        let (block, _) = SessionEditing.split(text)
        var values: [String: String] = [:]
        var order: [String] = []
        for line in block.components(separatedBy: "\n").dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard !key.isEmpty, values[key] == nil else { continue }
            values[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            order.append(key)
        }
        return (values, order)
    }

    /// A whole transcript from raw frontmatter + body, keys in the
    /// contract's order where known, unknown keys after.
    static func render(frontmatter: [String: String], order: [String]?, body: String) -> String {
        let known = ["title", "type", "source", "locale", "detected_locale", "started", "duration_sec",
                     "daisy_folder", "daisy_kind", "daisy_origin", "daisy_tag"]
        var keys = order ?? []
        if keys.isEmpty {
            keys = known.filter { frontmatter[$0] != nil } + frontmatter.keys.filter { !known.contains($0) && $0 != "tags" }.sorted()
            if frontmatter["tags"] != nil { keys.append("tags") }
        }
        var lines = ["---"]
        for key in keys { if let value = frontmatter[key] { lines.append("\(key): \(value)") } }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + body
    }

    static func syncablePaths(in dir: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where SyncPolicy.isSyncableFile(name) { out.append(name) }
        let shots = dir.appendingPathComponent(SyncPolicy.screenshotsDirectory)
        for name in (try? fm.contentsOfDirectory(atPath: shots.path)) ?? [] {
            let rel = SyncPolicy.screenshotsDirectory + "/" + name
            if SyncPolicy.isSyncableFile(rel) { out.append(rel) }
        }
        return out.sorted()
    }

    static func mtime(of url: URL) -> Double {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970
    }

    static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
