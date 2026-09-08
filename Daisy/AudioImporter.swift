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
//  Video (Ф4): mp4 / mov / m4v are accepted; only the audio track is
//  kept (`system_audio.m4a`: the track alone in a composition, passed
//  through when AAC, else re-encoded) — a library of webinars must not carry gigabytes of
//  picture Daisy never shows. The original video is never trashed even
//  in "move" mode, since the session holds only part of it. Containers
//  macOS can't open (mkv, webm, avi) are refused with a reason.
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
    case containerUnsupported(String)
    case noAudioTrack(String)

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
        case .containerUnsupported(let name):
            return String(localized: "macOS can't read “\(name)”. Convert it to mp4 or m4a first.")
        case .noAudioTrack(let name):
            return String(localized: "“\(name)” has no audio track.")
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
    nonisolated static let supportedExtensions: Set<String> =
        SessionAudioFiles.audioExtensions.union(videoExtensions)
    /// Video containers AVFoundation opens; only the audio track is kept.
    nonisolated static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// Video containers people have and macOS can't open — refused with
    /// a clear line instead of a generic "not an audio file".
    nonisolated static let knownUnreadableExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "ogg", "opus"]

    nonisolated static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func rejection(for url: URL) -> AudioImportError {
        knownUnreadableExtensions.contains(url.pathExtension.lowercased())
            ? .containerUnsupported(url.lastPathComponent)
            : .unsupportedType(url.lastPathComponent)
    }

    /// Import one file as a new audio-only session. Slow work (metadata
    /// probe, copy) runs off the main actor; only the store refresh is
    /// awaited here. Throws `AudioImportError` or a Foundation copy error;
    /// on any failure the half-made session directory is removed and the
    /// original file is never touched.
    static func importFile(
        _ source: URL,
        into folderSlug: String = SessionFolder.inbox.slug,
        mode: ImportMarker.Mode = .copy,
        title titleOverride: String? = nil
    ) async throws -> AudioImportResult {
        let name = source.lastPathComponent
        guard canImport(source) else { throw rejection(for: source) }
        // Finder drops arrive with a security scope; hold it for the
        // whole probe + copy (same as MeetingPreparationSheet.importPlanFile).
        // No-op for plain URLs.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Dragging an existing session's own audio out of a Daisy folder
        // with "move" would trash that session's only copy. Copy instead.
        // A video is never trashed either: the session keeps only its
        // sound, so "move" would destroy the picture.
        let effectiveMode: ImportMarker.Mode =
            (mode == .move && (source.path.contains("/Daisy/Sessions/") || isVideo(source))) ? .copy : mode

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
            title: titleOverride ?? title(fromFileName: name),
            startedAt: probe.startedAt,
            durationSec: probe.durationSec,
            folderSlug: folderSlug,
            sourcePath: source.path,
            originalName: name,
            mode: effectiveMode,
            importedAt: Date()
        )

        try await Task.detached(priority: .userInitiated) {
            try await materialize(source: source, into: directory, marker: marker)
        }.value

        log.info("Imported \(name, privacy: .private) as session \(sessionID, privacy: .private) (\(probe.durationSec)s, \(effectiveMode.rawValue, privacy: .public))")
        await SessionStore.shared.refresh()
        return AudioImportResult(sessionID: sessionID, directoryURL: directory, title: marker.title)
    }

    // MARK: - Inspection (for the import dialog)

    nonisolated struct Candidate: Identifiable, Sendable, Equatable {
        let url: URL
        /// Name of the dropped folder this file came from (its project),
        /// nil for a file dropped on its own.
        let folderName: String?
        /// Seconds, or nil when the file can't be read.
        let durationSec: Int?
        /// The recording's own date (see `probeAudio`), for ordering a
        /// batch chronologically.
        let startedAt: Date?
        let problem: String?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// Turn a Finder drop into the flat file list the dialog works on.
    /// A dropped folder contributes its audio files plus those of its
    /// immediate subfolders (one level, design Ф3) and names the
    /// project; deeper trees are left alone rather than swallowed.
    /// Non-audio files inside a folder are skipped silently — a folder
    /// of interviews usually carries notes and photos too, and listing
    /// each as "not an audio file" would bury the real problems. A
    /// directly dropped non-audio file IS listed, that one was deliberate.
    nonisolated static func expand(_ urls: [URL]) -> [(url: URL, folderName: String?)] {
        let fm = FileManager.default
        var out: [(url: URL, folderName: String?)] = []
        func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        func audioFiles(in directory: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
            .filter { !isDirectory($0) && canImport($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        for url in urls {
            guard isDirectory(url) else {
                out.append((url, nil))
                continue
            }
            let name = url.lastPathComponent
            out.append(contentsOf: audioFiles(in: url).map { ($0, name) })
            let subdirs = ((try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter(isDirectory)
            for sub in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                out.append(contentsOf: audioFiles(in: sub).map { ($0, name) })
            }
        }
        return out
    }

    /// Cheap look at each dropped file for the dialog: total duration
    /// from the container header (no decode), plus an honest per-file
    /// problem line for what can't be imported (design §6.8 — never a
    /// silent skip). Runs off-main; unsupported files are reported, not
    /// filtered, so the person sees why a file was left out. Folders are
    /// expanded first (see `expand`).
    nonisolated static func inspect(_ urls: [URL]) async -> [Candidate] {
        await Task.detached(priority: .userInitiated) {
            var out: [Candidate] = []
            for item in expand(urls) {
                let url = item.url
                let name = url.lastPathComponent
                guard canImport(url) else {
                    out.append(Candidate(url: url, folderName: item.folderName, durationSec: nil, startedAt: nil,
                                         problem: rejection(for: url).errorDescription))
                    continue
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let probe = try await probeAudio(at: url)
                    out.append(Candidate(url: url, folderName: item.folderName, durationSec: probe.durationSec,
                                         startedAt: probe.startedAt, problem: nil))
                } catch {
                    out.append(Candidate(url: url, folderName: item.folderName, durationSec: nil, startedAt: nil,
                                         problem: error.localizedDescription))
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
        let durationSec: Int
        if isVideo(url) {
            // Video: an audio track must exist; duration from the asset
            // header (no decode).
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
                // The extension says mp4/mov, the bytes don't.
                throw AudioImportError.unreadable(name)
            }
            guard !tracks.isEmpty else { throw AudioImportError.noAudioTrack(name) }
            let duration = (try? await asset.load(.duration)) ?? .invalid
            guard duration.isNumeric, duration.seconds.isFinite else {
                throw AudioImportError.unreadable(name)
            }
            durationSec = Int(duration.seconds.rounded())
            guard durationSec > 0 else { throw AudioImportError.unreadable(name) }
        } else {
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
            durationSec = Int((Double(frames) / sampleRate).rounded())
        }

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
    ) async throws {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let video = isVideo(source)
        let ext = video ? "m4a" : source.pathExtension.lowercased()
        let staging = directory
            .deletingLastPathComponent()
            .appendingPathComponent(".daisy-import-\(UUID().uuidString)", isDirectory: true)
        let destination = staging.appendingPathComponent("system_audio.\(ext)")

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer {
            if !committed { try? fm.removeItem(at: staging) }
        }

        if video {
            try await extractAudioTrack(from: source, to: destination)
        } else {
            try fm.copyItem(at: source, to: destination)
            let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -2
            guard sourceSize == copiedSize else {
                throw AudioImportError.copyVerificationFailed(name)
            }
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

    /// Audio track of a video → `.m4a`. The track is lifted into a
    /// composition of its own first: a passthrough export of the whole
    /// asset would refuse `.m4a` (it carries every track), whereas the
    /// audio-only composition passes through bit-exact when the track is
    /// AAC — seconds instead of a re-encode. If passthrough can't take
    /// the codec (LPCM, Opus in an mp4), fall back to an AAC re-encode.
    /// Whatever comes out must open in `AVAudioFile`, which is what
    /// transcription will use; otherwise the next preset is tried.
    nonisolated private static func extractAudioTrack(from source: URL, to destination: URL) async throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioImportError.noAudioTrack(name)
        }
        let composition = AVMutableComposition()
        guard let lane = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudioImportError.noAudioTrack(name) }
        let range = try await track.load(.timeRange)
        try lane.insertTimeRange(range, of: track, at: .zero)

        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset),
                  export.supportedFileTypes.contains(.m4a) else { continue }
            try? FileManager.default.removeItem(at: destination)
            do {
                if #available(macOS 15.0, *) {
                    try await export.export(to: destination, as: .m4a)
                } else {
                    export.outputURL = destination
                    export.outputFileType = .m4a
                    await export.export()
                    if let error = export.error { throw error }
                }
                if let check = try? AVAudioFile(forReading: destination), check.length > 0 {
                    return
                }
                log.info("Audio extraction with \(preset, privacy: .public) produced a file AVAudioFile can't read; trying the next preset")
            } catch {
                log.info("Audio extraction with \(preset, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try? FileManager.default.removeItem(at: destination)
        throw AudioImportError.noAudioTrack(name)
    }
}
