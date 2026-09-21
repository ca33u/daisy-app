//
//  SessionWriter.swift
//  DaisyCore
//
//  Atomic publication of a session folder (session-format.md §6.1, §7.3).
//
//  A recording is assembled inside a HIDDEN staging directory next to
//  the real sessions — `.daisy-recording-<id>/` — and moved into place
//  with one `rename` when it is complete. The scanner ignores hidden
//  entries (§1), so a half-written folder can never be mistaken for a
//  crashed recording. (The backlog said `<id>.tmp`; a visible `.tmp`
//  would need every reader to know about it, a hidden name needs none —
//  and §8 already lists exactly this family of names.)
//
//  The `.recording` marker is written ONLY when audio is being archived
//  (§6.1) and removed ONLY after `transcript.md` is safely on disk —
//  never earlier. A session published without a transcript keeps the
//  marker: it is a valid folder that still owes a finishing pass, which
//  is precisely what `SessionClassifier` will say about it.
//
//  Mirrors the Mac: RecordingSession.swift `makeSessionDirectory` +
//  marker write (≈1959), RecordingSession+Finalize.swift marker removal
//  (≈416), 1.0.7.72.
//

import Foundation
import os

public nonisolated enum SessionWriterError: Error, Equatable {
    /// §7.3: publishing a first transcript must fail loudly if
    /// `transcript.md` already exists.
    case transcriptAlreadyExists
    /// The staging directory disappeared before publish.
    case stagingMissing
    /// The destination name is taken (should not happen: ids are
    /// reserved at `begin`); surfaced rather than overwriting.
    case destinationExists(String)
}

/// Where sessions live: `<base>/Daisy/Sessions/` (§1).
public nonisolated struct SessionsBase: Sendable, Equatable {
    public let base: URL

    public init(base: URL) { self.base = base }

    /// The app container's Application Support — the only base on iPhone.
    public static func applicationSupport() -> SessionsBase {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return SessionsBase(base: appSupport)
    }

    public var sessionsDirectory: URL {
        base.appendingPathComponent("Daisy/Sessions", isDirectory: true)
    }

    /// Create `Daisy/Sessions` if needed and return it.
    public func ensureSessionsDirectory() throws -> URL {
        let dir = sessionsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// A session being assembled. Value type; the folder on disk is the state.
public nonisolated struct DraftSession: Sendable, Equatable {
    /// Session id (§1.1) — the name the folder will have once published.
    public let id: String
    public let startedAt: Date
    /// Hidden staging directory the recorder writes into.
    public let stagingURL: URL
    /// Where the folder lands on publish.
    public let publishedURL: URL

    public var microphoneURL: URL { stagingURL.appendingPathComponent("microphone.caf") }
    public var transcriptURL: URL { stagingURL.appendingPathComponent("transcript.md") }
    public var markerURL: URL { stagingURL.appendingPathComponent(SessionWriter.recordingMarkerName) }
}

public nonisolated enum SessionWriter {
    /// §6.1 — the in-progress marker. Same name as `SessionStore
    /// .recordingMarkerName` on the Mac.
    public static let recordingMarkerName = ".recording"
    /// §8 — staging directory family, hidden.
    public static let stagingPrefix = ".daisy-recording-"

    private static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "SessionWriter")

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Reserve an id and create the hidden staging directory.
    public static func begin(startedAt: Date, in base: SessionsBase) throws -> DraftSession {
        let sessions = try base.ensureSessionsDirectory()
        let fm = FileManager.default
        let id = SessionID.unique(for: startedAt, in: sessions) { candidate in
            fm.fileExists(atPath: sessions.appendingPathComponent(stagingPrefix + candidate).path)
        }
        let staging = sessions.appendingPathComponent(stagingPrefix + id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return DraftSession(
            id: id,
            startedAt: startedAt,
            stagingURL: staging,
            publishedURL: sessions.appendingPathComponent(id, isDirectory: true)
        )
    }

    /// §6.1 — write the marker, containing the ISO-8601 start instant.
    /// Call ONLY when audio is actually being archived into this folder.
    public static func writeRecordingMarker(_ draft: DraftSession) throws {
        try Data(iso.string(from: draft.startedAt).utf8).write(to: draft.markerURL)
    }

    /// Finished cleanly: write `transcript.md` atomically, remove the
    /// marker, move the folder into place. Order matters (§7.1): the
    /// marker goes only after the transcript is on disk.
    @discardableResult
    public static func publish(_ draft: DraftSession, transcript: String) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: draft.stagingURL.path) else { throw SessionWriterError.stagingMissing }
        guard !fm.fileExists(atPath: draft.transcriptURL.path) else {
            throw SessionWriterError.transcriptAlreadyExists
        }
        try Data(transcript.utf8).write(to: draft.transcriptURL, options: .atomic)
        try? fm.removeItem(at: draft.markerURL)
        return try move(draft)
    }

    /// Stopped without a transcript (no model yet, or transcription
    /// failed): move the folder into place as it is. The marker stays if
    /// audio was archived — the session is valid and owes a finishing
    /// pass (§6.1).
    @discardableResult
    public static func publishAudioOnly(_ draft: DraftSession) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: draft.stagingURL.path) else { throw SessionWriterError.stagingMissing }
        return try move(draft)
    }

    /// Nothing worth keeping (§7.5: under 10 s, no frames, no text).
    /// The only case a folder is removed by the app itself.
    public static func discard(_ draft: DraftSession) {
        try? FileManager.default.removeItem(at: draft.stagingURL)
    }

    /// Finishing pass on an already-published folder: write the
    /// transcript, then drop the marker. Fails loudly if a transcript
    /// already exists (§7.3).
    public static func finish(directory: URL, transcript: String) throws {
        let fm = FileManager.default
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        guard !fm.fileExists(atPath: transcriptURL.path) else {
            throw SessionWriterError.transcriptAlreadyExists
        }
        // §7.2 (backlog 8 G-2): a note the person wrote while this
        // session was still waiting is not overwritten by the pass — it
        // is what the pass writes.
        let text = SessionEditing.foldPendingNotes(into: transcript, sessionDirectory: directory)
        try Data(text.utf8).write(to: transcriptURL, options: .atomic)
        try? fm.removeItem(at: directory.appendingPathComponent(recordingMarkerName))
    }

    /// Leftover staging directories from a crash (§8). Safe to sweep at
    /// launch — except the one currently being recorded, which the
    /// caller names.
    public static func sweepStaging(in base: SessionsBase, keeping active: DraftSession? = nil) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: base.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(stagingPrefix) {
            if let active, url.standardizedFileURL == active.stagingURL.standardizedFileURL { continue }
            // A crashed recording's staging folder still has the audio.
            // Sweeping means PUBLISHING it, not deleting it: it becomes an
            // interrupted session the classifier hands to recovery.
            let id = String(url.lastPathComponent.dropFirst(stagingPrefix.count))
            let destination = base.sessionsDirectory.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                log.warning("Staging \(url.lastPathComponent, privacy: .public) left in place: destination exists")
                continue
            }
            do {
                try fm.moveItem(at: url, to: destination)
                log.notice("Published crashed staging folder \(id, privacy: .public) for recovery")
            } catch {
                log.error("Could not publish staging \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func move(_ draft: DraftSession) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: draft.publishedURL.path) {
            throw SessionWriterError.destinationExists(draft.id)
        }
        try fm.moveItem(at: draft.stagingURL, to: draft.publishedURL)
        log.info("Published session \(draft.id, privacy: .public)")
        return draft.publishedURL
    }
}
