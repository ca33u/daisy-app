//
//  MediaImport.swift
//  DaisyCore
//
//  backlog 13 М-3: transcribing a video or an audio file on the phone.
//  This is a PORT of the Mac's `AudioImporter` (daisy-app, import Ф0–Ф4),
//  not a new design — the same containers, the same refusals, the same
//  `import.json`, so a session imported on either device reads the same
//  on the other and the sync needs to learn nothing.
//
//  What the Mac decided and this keeps:
//   • only the containers AVFoundation actually opens (mp4/mov/m4v and
//     the audio list); mkv/webm/avi are refused BY NAME, because "not
//     an audio file" for a file the person clearly meant is a lie;
//   • a video contributes its audio track only (`system_audio.m4a`),
//     and the original is never touched — no "move" for video, ever;
//   • the session is assembled in a hidden `.daisy-import-<uuid>`
//     staging folder and moved into place in one step (§7.3), so a
//     half-made session never appears in the library;
//   • `import.json` carries title, date, duration and the source name
//     until a transcript exists.
//

import AVFoundation
import Foundation
import os

public nonisolated struct ImportMarker: Codable, Sendable, Equatable {
    public static let fileName = "import.json"

    public enum Mode: String, Codable, Sendable {
        case copy
        case move
    }

    public var title: String
    public var startedAt: Date
    public var durationSec: Int
    public var folderSlug: String
    public var sourcePath: String
    public var originalName: String
    public var mode: Mode
    public var importedAt: Date

    public init(title: String, startedAt: Date, durationSec: Int, folderSlug: String,
                sourcePath: String, originalName: String, mode: Mode, importedAt: Date) {
        self.title = title
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.folderSlug = folderSlug
        self.sourcePath = sourcePath
        self.originalName = originalName
        self.mode = mode
        self.importedAt = importedAt
    }

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: directory).path)
    }

    public static func load(from directory: URL) -> ImportMarker? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportMarker.self, from: data)
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}

public nonisolated enum MediaImportError: LocalizedError, Equatable {
    case unsupportedType(String)
    case containerUnsupported(String)
    case noAudioTrack(String)
    case unreadable(String)
    case copyVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            String(localized: "“\(name)” isn't an audio or video file Daisy can read.")
        case .containerUnsupported(let name):
            String(localized: "iOS can't read “\(name)”. Convert it to mp4 or m4a first.")
        case .noAudioTrack(let name):
            String(localized: "“\(name)” has no audio track.")
        case .unreadable(let name):
            String(localized: "“\(name)” couldn't be read to the end.")
        case .copyVerificationFailed(let name):
            String(localized: "Copying “\(name)” didn't finish cleanly. The original was left untouched.")
        }
    }
}

public nonisolated struct MediaImportResult: Sendable, Equatable {
    public let sessionID: String
    public let directoryURL: URL
    public let title: String
    public let durationSec: Int
}

public nonisolated enum MediaImport {
    private static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "MediaImport")

    /// Video containers AVFoundation opens; only the audio track is kept.
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// Containers people have and the system cannot open — refused with
    /// a clear line rather than a generic "not an audio file".
    public static let knownUnreadableExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "ogg", "opus"]
    /// Everything accepted. Must stay a subset of what the library scan
    /// recognises, or the copied file would be invisible.
    public static var supportedExtensions: Set<String> {
        SessionAudioFiles.audioExtensions.union(videoExtensions)
    }

    public static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// The message a person reads — for tests and for callers that
    /// want it without catching.
    public static func errorText(_ error: MediaImportError) -> String {
        error.errorDescription ?? ""
    }

    public static func rejection(for url: URL) -> MediaImportError {
        knownUnreadableExtensions.contains(url.pathExtension.lowercased())
            ? .containerUnsupported(url.lastPathComponent)
            : .unsupportedType(url.lastPathComponent)
    }

    /// A readable title from a file name: "Interview 2026-03-04.m4a" →
    /// "Interview 2026-03-04".
    public static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? name : cleaned
    }

    // MARK: - Probe

    public struct Probe: Sendable, Equatable {
        public let durationSec: Int
        public let startedAt: Date
    }

    /// Duration and the recording's own date, without decoding. Throws
    /// the same refusals the import will.
    public static func probe(_ url: URL) async throws -> Probe {
        let name = url.lastPathComponent
        guard canImport(url) else { throw rejection(for: url) }
        let durationSec: Int
        if isVideo(url) {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
                throw MediaImportError.unreadable(name)
            }
            guard !tracks.isEmpty else { throw MediaImportError.noAudioTrack(name) }
            let duration = (try? await asset.load(.duration)) ?? .invalid
            guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                throw MediaImportError.unreadable(name)
            }
            durationSec = Int(duration.seconds.rounded())
        } else {
            // `AVAudioFile` is what the transcription will use — if it
            // cannot open the file now, the session would be a dead end.
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
                throw MediaImportError.unreadable(name)
            }
            durationSec = Int((Double(file.length) / file.processingFormat.sampleRate).rounded())
            guard durationSec > 0 else { throw MediaImportError.unreadable(name) }
        }
        return Probe(durationSec: durationSec, startedAt: fileDate(of: url))
    }

    /// The recording's own date where the file system knows it, the
    /// modification date otherwise — never "now", so an imported
    /// interview sorts where it happened.
    public static func fileDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    // MARK: - Import

    /// Build a session from one file. Staging → atomic move (§7.3); on
    /// any failure nothing is left behind and the original is untouched.
    public static func importFile(
        _ source: URL,
        into base: SessionsBase,
        folderSlug: String = "inbox",
        titleOverride: String? = nil
    ) async throws -> MediaImportResult {
        let name = source.lastPathComponent
        guard canImport(source) else { throw rejection(for: source) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let probe = try await probe(source)
        let sessionsDirectory = try base.ensureSessionsDirectory()
        let sessionID = SessionID.unique(for: probe.startedAt, in: sessionsDirectory)
        let directory = sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
        let marker = ImportMarker(
            title: titleOverride ?? title(fromFileName: name),
            startedAt: probe.startedAt,
            durationSec: probe.durationSec,
            folderSlug: folderSlug,
            sourcePath: source.path,
            originalName: name,
            // The phone only ever copies: the file belongs to Files, to
            // another app, or to iCloud, and moving it is not ours to do.
            mode: .copy,
            importedAt: Date()
        )

        let fm = FileManager.default
        let video = isVideo(source)
        let ext = video ? "m4a" : source.pathExtension.lowercased()
        let staging = sessionsDirectory.appendingPathComponent(".daisy-import-\(UUID().uuidString)", isDirectory: true)
        let destination = staging.appendingPathComponent("system_audio.\(ext)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }

        if video {
            try await extractAudioTrack(from: source, to: destination)
        } else {
            try fm.copyItem(at: source, to: destination)
            let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -2
            guard sourceSize == copiedSize else { throw MediaImportError.copyVerificationFailed(name) }
        }

        try marker.write(to: staging)
        try fm.moveItem(at: staging, to: directory)
        committed = true
        log.info("Imported \(name, privacy: .private) as \(sessionID, privacy: .public) (\(probe.durationSec, privacy: .public) s)")
        return MediaImportResult(sessionID: sessionID, directoryURL: directory,
                                 title: marker.title, durationSec: probe.durationSec)
    }

    /// Video → its audio track as m4a. Passthrough first (no re-encode,
    /// seconds instead of minutes on a two-hour file); AppleM4A as the
    /// fallback for tracks passthrough refuses.
    public static func extractAudioTrack(from source: URL, to destination: URL) async throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaImportError.noAudioTrack(name)
        }
        let composition = AVMutableComposition()
        guard let lane = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaImportError.noAudioTrack(name)
        }
        let range = try await track.load(.timeRange)
        try lane.insertTimeRange(range, of: track, at: .zero)

        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset),
                  export.supportedFileTypes.contains(.m4a) else { continue }
            try? FileManager.default.removeItem(at: destination)
            do {
                try await export.export(to: destination, as: .m4a)
                if let check = try? AVAudioFile(forReading: destination), check.length > 0 { return }
                log.info("Extraction with \(preset, privacy: .public) produced a file AVAudioFile can't read; trying the next preset")
            } catch {
                log.info("Extraction with \(preset, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try? FileManager.default.removeItem(at: destination)
        throw MediaImportError.noAudioTrack(name)
    }
}
