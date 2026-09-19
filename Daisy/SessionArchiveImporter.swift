//
//  SessionArchiveImporter.swift
//  Daisy
//
//  `.daisysession` (backlog 4, part C): a zip of one session folder,
//  exported by Daisy for iPhone (UTType `com.daisy.session`, conforms to
//  `public.zip-archive`). Unzipped it IS a session folder by the
//  contract (session-format.md) — transcript.md, microphone.caf, maybe
//  summary.json — so importing means: unzip, keep the folder's own ID
//  (suffix `-2`, `-3`… only if that ID is already taken), move it into
//  `Daisy/Sessions/`, rescan. No re-encoding, no sidecar: the Library
//  then treats it like any other session, including diarization and
//  "Transcribe again", which read the audio that is already there.
//
//  Unzipping goes through `ditto -x -k` — the same tool Finder uses,
//  handles the `__MACOSX` resource forks and unicode names, and Daisy is
//  not sandboxed so a helper process is fine.
//

import Foundation
import os

nonisolated enum SessionArchiveImporter {
    static let fileExtension = "daisysession"
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SessionArchiveImport")

    enum ImportError: LocalizedError {
        case notASessionArchive(String)
        case unzipFailed(String)
        case nothingInside(String)
        case noSessionsFolder

        var errorDescription: String? {
            switch self {
            case .notASessionArchive(let name):
                return String(localized: "\(name) is not a .daisysession file.")
            case .unzipFailed(let name):
                return String(localized: "Couldn't unpack \(name).")
            case .nothingInside(let name):
                return String(localized: "\(name) doesn't contain a session (no transcript.md and no audio).")
            case .noSessionsFolder:
                return String(localized: "The sessions folder isn't available.")
            }
        }
    }

    static func isSessionArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Finder "Open With", Dock drop, Library drop: unpack into the
    /// configured sessions folder and rescan the Library.
    @MainActor
    static func importArchive(_ archive: URL) async throws -> URL {
        guard let ticket = SessionsFolder.acquireBase() else { throw ImportError.noSessionsFolder }
        defer { ticket.release() }
        let sessionsDir = SessionsFolder.sessionsDirectory(in: ticket.url)
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        let directory = try await Task.detached(priority: .userInitiated) {
            try importArchive(archive, into: sessionsDir)
        }.value
        await SessionStore.shared.refresh()
        return directory
    }

    /// Import several, one toast at the end — what Finder / Dock / the
    /// Library drop all call.
    @MainActor
    static func importAndReport(_ archives: [URL]) async {
        var imported = 0
        var failures: [String] = []
        for archive in archives {
            do {
                _ = try await importArchive(archive)
                imported += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if imported > 0 {
            ToastCenter.shared.show(
                imported == 1
                    ? String(localized: "Session imported from iPhone.")
                    : String(localized: "\(imported) sessions imported from iPhone."),
                style: .success
            )
        }
        if let first = failures.first {
            ToastCenter.shared.show(first, style: .error)
        }
    }

    /// The file-system part, testable against any sessions directory.
    /// Returns the session folder now living under `sessionsDir`.
    static func importArchive(_ archive: URL, into sessionsDir: URL) throws -> URL {
        guard isSessionArchive(archive) else { throw ImportError.notASessionArchive(archive.lastPathComponent) }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("daisysession-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        try unzip(archive, into: scratch)
        let source = try sessionFolder(in: scratch, archiveName: archive.lastPathComponent)

        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let id = uniqueID(preferring: source.lastPathComponent, in: sessionsDir)
        let destination = sessionsDir.appendingPathComponent(id, isDirectory: true)
        try fm.moveItem(at: source, to: destination)
        log.info("Imported \(archive.lastPathComponent, privacy: .private) as session \(id, privacy: .private)")
        return destination
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ImportError.unzipFailed(archive.lastPathComponent)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.unzipFailed(archive.lastPathComponent) }
    }

    /// The archive normally holds one top-level folder (the session, named
    /// by its ID). A zip of loose files is accepted too — the archive's
    /// own name then becomes the ID.
    private static func sessionFolder(in scratch: URL, archiveName: String) throws -> URL {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { !$0.lastPathComponent.hasPrefix("__MACOSX") && !$0.lastPathComponent.hasPrefix(".") } ?? []
        let candidate: URL
        if entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            candidate = entries[0]
        } else {
            let stem = (archiveName as NSString).deletingPathExtension
            let wrapped = scratch.appendingPathComponent(stem, isDirectory: true)
            try fm.createDirectory(at: wrapped, withIntermediateDirectories: true)
            for entry in entries {
                try fm.moveItem(at: entry, to: wrapped.appendingPathComponent(entry.lastPathComponent))
            }
            candidate = wrapped
        }
        let hasTranscript = fm.fileExists(atPath: candidate.appendingPathComponent("transcript.md").path)
        let audio = SessionAudioFiles.discover(in: candidate)
        guard hasTranscript || !audio.microphone.isEmpty || !audio.system.isEmpty else {
            throw ImportError.nothingInside(archiveName)
        }
        return candidate
    }

    /// The folder keeps its ID (it is the session's identity on both
    /// devices) unless that name is already taken here.
    static func uniqueID(preferring id: String, in sessionsDir: URL) -> String {
        let fm = FileManager.default
        var candidate = id
        var n = 2
        while fm.fileExists(atPath: sessionsDir.appendingPathComponent(candidate).path) {
            candidate = "\(id)-\(n)"
            n += 1
        }
        return candidate
    }
}
