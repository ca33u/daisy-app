//
//  AudioImporter.swift
//  Daisy
//
//  Turn an audio file the user already has (Voice Memos export, Zoom
//  download, interview .m4a from a phone) into a Daisy session.
//
//  Design (Projects/Daisy/2026-08-31-audio-import-design.md), phase Ф0:
//    • file = session, folder = project;
//    • the session's date comes from the FILE (track metadata →
//      creation → modification → now), never from the moment of import,
//      so ten old interviews don't collapse into one "today";
//    • the original container is kept as-is (`system_audio.<ext>`) — no
//      lossy re-encode; `AVAudioFile` reads it directly when the user
//      presses "Transcribe audio". It goes under the SYSTEM prefix, not
//      `microphone`: the mic channel is "the user, by definition"
//      (`TranscriptSegment.speakerLabel` stamps the display name on
//      every mic segment, no diarization), whereas an imported interview
//      is other people talking — the system channel diarizes them into
//      Remote A / B / … which the speaker map can then rename;
//    • an `import.json` sidecar carries title/date/project until the
//      first transcript exists, and — crucially — tells
//      `SessionStore.classify` this is NOT a crashed recording (an
//      audio-only folder with no transcript otherwise looks exactly like
//      one and would be sent to InterruptedRecordingRecovery).
//
//  Phase Ф0 has no dialog: drop → copy → session in `.audioOnly` state.
//  Copy/move choice, the queue, folders→projects and video come later.
//

import AVFoundation
import Foundation
import os

/// Sidecar written next to the imported audio. Read by
/// `SessionStore.parseSession` (title/date/project while there is no
/// transcript) and `SessionStore.classify` (never treat as interrupted).
/// Folded into `transcript.md` frontmatter by the first
/// "Transcribe audio" run (`SessionAudioProcessing.renderDerivedTranscript`).
nonisolated struct ImportMarker: Codable, Sendable, Equatable {
    static let fileName = "import.json"

    enum Mode: String, Codable, Sendable {
        case copy
        case move
    }

    var title: String
    var startedAt: Date
    var durationSec: Int
    var folderSlug: String
    var sourcePath: String
    var originalName: String
    var mode: Mode
    var importedAt: Date

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: directory).path)
    }

    static func load(from directory: URL) -> ImportMarker? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportMarker.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}

nonisolated enum AudioImportError: LocalizedError, Equatable {
    case unsupportedType(String)
    case unreadable(String)
    case noSessionsFolder
    case copyVerificationFailed(String)
    case inCloud(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return String(localized: "“\(name)” isn't an audio file Daisy can import.")
        case .unreadable(let name):
            return String(localized: "Daisy couldn't read any audio from “\(name)”.")
        case .noSessionsFolder:
            return String(localized: "Daisy couldn't write to the recordings folder. Choose its storage folder again in Settings.")
        case .copyVerificationFailed(let name):
            return String(localized: "Copying “\(name)” didn't finish cleanly. The original was left untouched.")
        case .inCloud(let name):
            return String(localized: "“\(name)” is in iCloud and not on this Mac yet. Download it in Finder first.")
        }
    }
}

nonisolated struct AudioImportResult: Sendable, Equatable {
    let sessionID: String
    let directoryURL: URL
    let title: String
}

@MainActor
enum AudioImporter {
    nonisolated private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioImport")

    /// Containers accepted on drop. Must stay a subset of
    /// `SessionAudioFiles.audioExtensions`, or the copied file would be
    /// invisible to the Library scan.
    nonisolated static let supportedExtensions: Set<String> = SessionAudioFiles.audioExtensions

    nonisolated static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Import one file as a new audio-only session. Slow work (metadata
    /// probe, copy) runs off the main actor; only the store refresh is
    /// awaited here. Throws `AudioImportError` or a Foundation copy error;
    /// on any failure the half-made session directory is removed and the
    /// original file is never touched.
    static func importFile(
        _ source: URL,
        into folderSlug: String = SessionFolder.inbox.slug,
        mode: ImportMarker.Mode = .copy
    ) async throws -> AudioImportResult {
        let name = source.lastPathComponent
        guard canImport(source) else { throw AudioImportError.unsupportedType(name) }
        // Finder drops arrive with a security scope; hold it for the
        // whole probe + copy (same as MeetingPreparationSheet.importPlanFile).
        // No-op for plain URLs.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Dragging an existing session's own audio out of a Daisy folder
        // with "move" would trash that session's only copy. Copy instead.
        let effectiveMode: ImportMarker.Mode =
            (mode == .move && source.path.contains("/Daisy/Sessions/")) ? .copy : mode

        let probe = try await Task.detached(priority: .userInitiated) {
            try await probeAudio(at: source)
        }.value

        guard let ticket = SessionsFolder.acquireBase() else {
            throw AudioImportError.noSessionsFolder
        }
        defer { ticket.release() }
        let sessionsDir = SessionsFolder.sessionsDirectory(in: ticket.url)
        let sessionID = uniqueSessionID(for: probe.startedAt, in: sessionsDir)
        let directory = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        let marker = ImportMarker(
            title: title(fromFileName: name),
            startedAt: probe.startedAt,
            durationSec: probe.durationSec,
            folderSlug: folderSlug,
            sourcePath: source.path,
            originalName: name,
            mode: effectiveMode,
            importedAt: Date()
        )

        try await Task.detached(priority: .userInitiated) {
            try materialize(source: source, into: directory, marker: marker)
        }.value

        log.info("Imported \(name, privacy: .private) as session \(sessionID, privacy: .private) (\(probe.durationSec)s, \(effectiveMode.rawValue, privacy: .public))")
        await SessionStore.shared.refresh()
        return AudioImportResult(sessionID: sessionID, directoryURL: directory, title: marker.title)
    }

    // MARK: - Inspection (for the import dialog)

    nonisolated struct Candidate: Identifiable, Sendable, Equatable {
        let url: URL
        /// Seconds, or nil when the file can't be read.
        let durationSec: Int?
        let problem: String?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// Cheap look at each dropped file for the dialog: total duration
    /// from the container header (no decode), plus an honest per-file
    /// problem line for what can't be imported (design §6.8 — never a
    /// silent skip). Runs off-main; unsupported files are reported, not
    /// filtered, so the person sees why a file was left out.
    nonisolated static func inspect(_ urls: [URL]) async -> [Candidate] {
        await Task.detached(priority: .userInitiated) {
            var out: [Candidate] = []
            for url in urls {
                let name = url.lastPathComponent
                guard canImport(url) else {
                    out.append(Candidate(url: url, durationSec: nil,
                                         problem: AudioImportError.unsupportedType(name).errorDescription))
                    continue
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let probe = try await probeAudio(at: url)
                    out.append(Candidate(url: url, durationSec: probe.durationSec, problem: nil))
                } catch {
                    out.append(Candidate(url: url, durationSec: nil, problem: error.localizedDescription))
                }
            }
            return out
        }.value
    }

    // MARK: - Pieces

    nonisolated private struct Probe: Sendable {
        var startedAt: Date
        var durationSec: Int
    }

    /// Verify the file decodes and pull its date + duration. Runs
    /// off-main (caller wraps in Task.detached).
    nonisolated private static func probeAudio(at url: URL) async throws -> Probe {
        let name = url.lastPathComponent
        // An evicted iCloud file opens but reads fail halfway (and on a
        // full disk the implicit download fails too) — see
        // daisy-icloud-eviction-data-loss. Refuse up front instead.
        guard !SessionStore.isCloudEvicted(url) else { throw AudioImportError.inCloud(name) }
        // `AVAudioFile` is what transcription will use later — if it
        // can't open the file now, the session would be a dead end.
        let frames: AVAudioFramePosition
        let sampleRate: Double
        do {
            let file = try AVAudioFile(forReading: url)
            frames = file.length
            sampleRate = file.processingFormat.sampleRate
        } catch {
            throw AudioImportError.unreadable(name)
        }
        guard frames > 0, sampleRate > 0 else { throw AudioImportError.unreadable(name) }
        let durationSec = Int((Double(frames) / sampleRate).rounded())

        // Recording date, most trustworthy first. Track metadata is what
        // Voice Memos / phones stamp; file dates survive plain copies but
        // not downloads (a Zoom recording downloaded today would land on
        // "today" — still better than the import moment for the rest).
        var startedAt: Date?
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            startedAt = date
        }
        if startedAt == nil {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            startedAt = values?.creationDate ?? values?.contentModificationDate
        }
        return Probe(startedAt: startedAt ?? Date(), durationSec: durationSec)
    }

    /// Same shape as live recordings (`RecordingSession.makeSessionDirectory`):
    /// ISO-8601 UTC with `:` → `-`. A second file with the same second gets a
    /// numeric suffix; `parseSession` reads the real date from `import.json`
    /// so the suffix never shows through.
    nonisolated static func uniqueSessionID(for date: Date, in sessionsDir: URL) -> String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let base = stamp.string(from: date).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: sessionsDir.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// "acme_interview-2026-03-12.m4a" → "acme interview-2026-03-12".
    /// Underscores are almost always stand-ins for spaces; hyphens are
    /// often meaningful (dates, names), so they stay.
    nonisolated static func title(fromFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let cleaned = stem
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return cleaned.isEmpty ? stem : cleaned
    }

    /// Copy the audio into a HIDDEN staging directory next to the
    /// sessions, verify, write the sidecar, then rename into place in
    /// one step. The Library scan skips hidden entries, so it never sees
    /// a half-copied file — which, at ≥256 KB and with no transcript,
    /// would otherwise classify as a crashed recording and kick off
    /// recovery mid-copy (the folder watcher fires on every write).
    /// Staging is removed on any failure; the original is never touched
    /// except for `.move`, which trashes it only after the rename.
    nonisolated private static func materialize(
        source: URL,
        into directory: URL,
        marker: ImportMarker
    ) throws {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let ext = source.pathExtension.lowercased()
        let staging = directory
            .deletingLastPathComponent()
            .appendingPathComponent(".daisy-import-\(UUID().uuidString)", isDirectory: true)
        let destination = staging.appendingPathComponent("system_audio.\(ext)")

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer {
            if !committed { try? fm.removeItem(at: staging) }
        }

        try fm.copyItem(at: source, to: destination)
        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -2
        guard sourceSize == copiedSize else {
            throw AudioImportError.copyVerificationFailed(name)
        }

        try marker.write(to: staging)
        try fm.moveItem(at: staging, to: directory)
        committed = true

        if marker.mode == .move {
            // Trash, not delete: the user's file must stay recoverable
            // even if the session later turns out to be unwanted.
            do {
                try fm.trashItem(at: source, resultingItemURL: nil)
            } catch {
                log.warning("Imported copy is in place but the original couldn't be moved to Trash: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
