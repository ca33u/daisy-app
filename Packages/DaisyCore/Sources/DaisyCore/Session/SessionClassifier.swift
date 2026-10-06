//
//  SessionClassifier.swift
//  DaisyCore
//
//  session-format.md §6 — is this folder finished, interrupted, or
//  unreadable? Copied from daisy-app `SessionStore.classify(directory:)`
//  and `scanRoots` (SessionStore.swift ≈ 300–480, macOS Daisy 1.0.7.72),
//  minus the `StoredSession` payload the Mac builds alongside: here the
//  verdict is the product, and a small `SessionSummary` (title, date,
//  duration, what's on disk) is what a Library list needs.
//
//  Rules, verbatim from the Mac:
//   • interrupted ⇔ audio exists, no finished transcript, no
//     `import.json`, nothing cloud-evicted, and (marker present OR the
//     largest audio file ≥ 256 KB);
//   • "finished transcript" ⇔ `transcript.md` exists and (body non-empty
//     OR `title` / `started` in frontmatter);
//   • unreadable ⇔ the directory cannot be listed. Never modified.
//   • the scan is non-recursive, skips hidden entries, directories only.
//

import Foundation

public nonisolated enum SessionState: Sendable, Equatable {
    case valid
    case interrupted
    case unreadable
}

/// What a Library row needs, read once per folder.
public nonisolated struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let directoryURL: URL
    public let state: SessionState
    public let title: String
    public let startedAt: Date
    public let durationSec: Int
    public let kind: SessionKind
    public let hasTranscript: Bool
    public let hasAudio: Bool
    /// `.recording` present — on a `.valid` folder this means "quit during
    /// a recording, the final pass never ran" (§6.1: finishing pass).
    public let hasRecordingMarker: Bool
    public let origin: String?
    /// `daisy_folder` slug (§9); `inbox` when absent.
    public let folder: String
    /// An `import.json` sits beside the audio: a file the person
    /// imported, not a recording. It is `.valid` (nothing was
    /// interrupted), but it still owes a transcript — backlog 13 М-3.
    public let isImported: Bool

    /// Audio, no transcript, and nobody is recording into it: something
    /// the transcription queue should pick up. True for an interrupted
    /// recording, for a session whose finishing pass never ran, and for
    /// an imported file.
    public var needsTranscription: Bool {
        guard hasAudio, !hasTranscript, state != .unreadable else { return false }
        return state == .interrupted || needsFinishingPass || isImported
    }

    /// A valid folder that still carries the marker owes a finishing pass.
    public var needsFinishingPass: Bool { state == .valid && hasRecordingMarker && !hasTranscript }
    public var transcriptURL: URL? {
        hasTranscript ? directoryURL.appendingPathComponent("transcript.md") : nil
    }
}

public nonisolated enum SessionClassifier {
    public static let recordingMarkerName = SessionWriter.recordingMarkerName
    /// A marker-less audio file must reach this size before the folder
    /// counts as an interrupted recording.
    public static let minRecoverableAudioBytes: Int64 = 256 * 1024

    /// §6 verdict for one folder.
    public static func classify(directory: URL) -> SessionState {
        inspect(directory: directory).state
    }

    /// The verdict, and the transcript's text when it was read for it —
    /// so `summarize` does not read every `transcript.md` a second time
    /// (the scan runs on each Library refresh).
    static func inspect(directory: URL) -> (state: SessionState, transcript: String?) {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: directory.path)) != nil else {
            return (.unreadable, nil)
        }
        var transcriptText: String?
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let retainedAudio = SessionAudioFiles.discover(in: directory)
        let hasAudio = retainedAudio.hasAny
        let hasTranscript = fm.fileExists(atPath: transcriptURL.path)

        let transcriptEvicted = hasTranscript && isCloudEvicted(transcriptURL)
        var transcriptUnreadable = false
        var transcriptBodyEmpty = true
        var hasMeaningfulFrontmatter = false
        if hasTranscript, !transcriptEvicted {
            do {
                let text = try String(contentsOf: transcriptURL, encoding: .utf8)
                transcriptText = text
                let parsed = SessionDocument.parseFrontmatter(in: text)
                transcriptBodyEmpty = parsed.body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                hasMeaningfulFrontmatter = parsed.title != nil || parsed.started != nil
            } catch {
                transcriptUnreadable = true
            }
        }

        let hasFinishedTranscript = hasTranscript
            && (!transcriptBodyEmpty || hasMeaningfulFrontmatter)
        let hasMarker = fm.fileExists(
            atPath: directory.appendingPathComponent(recordingMarkerName).path
        )
        let audioEvicted = retainedAudio.all.contains(where: isCloudEvicted)
        let isImported = !hasMarker && fm.fileExists(atPath: directory.appendingPathComponent("import.json").path)
        if hasAudio, !hasFinishedTranscript, !isImported,
           !transcriptEvicted, !transcriptUnreadable, !audioEvicted,
           hasMarker || largestAudioBytes(retainedAudio.all) >= minRecoverableAudioBytes {
            return (.interrupted, transcriptText)
        }
        return (.valid, transcriptText)
    }

    /// Verdict plus the row data. nil for an unreadable folder.
    public static func summarize(directory: URL) -> SessionSummary? {
        let (state, transcriptText) = inspect(directory: directory)
        guard state != .unreadable else { return nil }
        let fm = FileManager.default
        let id = directory.lastPathComponent
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let audio = SessionAudioFiles.discover(in: directory)
        let directoryDates = try? directory.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        var title = id
        var startedAt = SessionID.parse(id)
            ?? directoryDates?.creationDate
            ?? directoryDates?.contentModificationDate
            ?? .distantPast
        var durationSec = 0
        var kind: SessionKind = .recording
        var origin: String?
        var folder = "inbox"
        let isImported = ImportMarker.exists(in: directory)
        let hasTranscript = fm.fileExists(atPath: transcriptURL.path)
        if hasTranscript, let text = transcriptText {
            let parsed = SessionDocument.parseFrontmatter(in: text)
            title = parsed.title ?? title
            if let s = parsed.started, let d = SessionFrontmatter.parse(text)?.started ?? ISO8601DateFormatter().date(from: s) {
                startedAt = d
            }
            durationSec = parsed.durationSec ?? 0
            if let k = parsed.kind.flatMap(SessionKind.init(rawValue:)) { kind = k }
            origin = parsed["daisy_origin"]
            if let f = parsed["daisy_folder"]?.lowercased(), !f.isEmpty { folder = f }
        } else if isImported, let marker = ImportMarker.load(from: directory) {
            // An import waiting for its transcript already knows what it
            // is — the row said «2026-09-27T14-26-28Z» and no length
            // until the queue got to it (27.09).
            title = marker.title
            startedAt = marker.startedAt
            durationSec = marker.durationSec
            if !marker.folderSlug.isEmpty { folder = marker.folderSlug.lowercased() }
        } else if let markerText = try? String(contentsOf: directory.appendingPathComponent(recordingMarkerName), encoding: .utf8),
                  let d = ISO8601DateFormatter().date(from: markerText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            startedAt = d
        }
        // A recording still waiting for its transcript reads as the
        // transcript will name it, not as its folder (27.09, the phone's
        // rows said «2026-09-27T15-09-44Z» until the queue got there).
        if !hasTranscript, !isImported, startedAt != .distantPast {
            title = TranscriptDocument.defaultTitle(for: startedAt)
        }
        return SessionSummary(
            id: id,
            directoryURL: directory,
            state: state,
            title: title,
            startedAt: startedAt,
            durationSec: durationSec,
            kind: kind,
            hasTranscript: hasTranscript,
            hasAudio: audio.hasAny,
            hasRecordingMarker: fm.fileExists(atPath: directory.appendingPathComponent(recordingMarkerName).path),
            origin: origin,
            folder: folder,
            isImported: isImported
        )
    }

    /// §1 scan: non-recursive, hidden entries skipped, directories only.
    /// Newest first. Unreadable folders are left out (and never touched).
    ///
    /// With a `cache`, a folder whose directory and `transcript.md` have
    /// not changed since the last scan keeps its summary without being
    /// read again (audit 02.10, Н-6: the Library is rescanned on every
    /// refresh, and every refresh read every transcript in full). A
    /// folder's listing changes its directory's modification date, an
    /// edit changes the transcript's; audio in a published folder only
    /// comes and goes, never grows.
    public static func scan(base: SessionsBase, cache: SessionScanCache? = nil) -> [SessionSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: base.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        let known = cache?.entries ?? [:]
        var fresh: [String: (stamp: SessionScanCache.Stamp, summary: SessionSummary)] = [:]
        let summaries: [SessionSummary] = entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false else { return nil }
            let id = url.lastPathComponent
            let stamp = SessionScanCache.stamp(of: url)
            if let hit = known[id], hit.stamp == stamp {
                fresh[id] = hit
                return hit.summary
            }
            guard let summary = summarize(directory: url) else { return nil }
            fresh[id] = (stamp, summary)
            return summary
        }
        cache?.entries = fresh
        return summaries.sorted { $0.startedAt > $1.startedAt }
    }

    /// §6.2 — evicted to cloud storage: present but unreadable, never
    /// absent. Non-cloud files always return false.
    public static func isCloudEvicted(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]) else { return false }
        guard values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status == .notDownloaded
    }

    /// Largest retained audio file in bytes (0 if none is readable).
    public static func largestAudioBytes(_ urls: [URL]) -> Int64 {
        urls.map { url -> Int64 in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Int64(size)
        }.max() ?? 0
    }
}

/// What a scan remembers between runs — one entry per folder, keyed by
/// the folder's and its transcript's modification dates.
public nonisolated final class SessionScanCache: @unchecked Sendable {
    public struct Stamp: Equatable, Sendable {
        public var directory: Date?
        public var transcript: Date?
    }
    private let lock = NSLock()
    private var storage: [String: (stamp: Stamp, summary: SessionSummary)] = [:]
    var entries: [String: (stamp: Stamp, summary: SessionSummary)] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    public init() {}

    /// Forget one folder (its files changed in a way the dates may not
    /// show — a file rewritten in place within the same second).
    public func invalidate(_ id: String) { lock.withLock { storage[id] = nil } }
    public func invalidateAll() { lock.withLock { storage.removeAll() } }

    static func stamp(of directory: URL) -> Stamp {
        let dir = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let transcript = (try? directory.appendingPathComponent("transcript.md")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Stamp(directory: dir, transcript: transcript)
    }
}
