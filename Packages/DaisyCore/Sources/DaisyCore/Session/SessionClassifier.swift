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
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: directory.path)) != nil else {
            return .unreadable
        }
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
            return .interrupted
        }
        return .valid
    }

    /// Verdict plus the row data. nil for an unreadable folder.
    public static func summarize(directory: URL) -> SessionSummary? {
        let state = classify(directory: directory)
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
        if hasTranscript, !isCloudEvicted(transcriptURL),
           let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let parsed = SessionDocument.parseFrontmatter(in: text)
            title = parsed.title ?? title
            if let s = parsed.started, let d = SessionFrontmatter.parse(text)?.started ?? ISO8601DateFormatter().date(from: s) {
                startedAt = d
            }
            durationSec = parsed.durationSec ?? 0
            if let k = parsed.kind.flatMap(SessionKind.init(rawValue:)) { kind = k }
            origin = parsed["daisy_origin"]
            if let f = parsed["daisy_folder"]?.lowercased(), !f.isEmpty { folder = f }
        } else if let markerText = try? String(contentsOf: directory.appendingPathComponent(recordingMarkerName), encoding: .utf8),
                  let d = ISO8601DateFormatter().date(from: markerText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            startedAt = d
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
    public static func scan(base: SessionsBase) -> [SessionSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: base.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .compactMap { summarize(directory: $0) }
            .sorted { $0.startedAt > $1.startedAt }
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
