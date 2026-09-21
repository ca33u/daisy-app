//
//  SessionArchiveExporter.swift
//  Daisy
//
//  backlog 8 G-3: the other direction of `.daisysession`. The iPhone
//  exports a session as a zip of its folder (`SessionArchiver` in
//  DaisyLite) and this app imports it (`SessionArchiveImporter`); now
//  the Mac exports the same file, the same way — `NSFileCoordinator`
//  with `.forUploading`, which hands back a zip of a directory whose
//  top-level entry is the folder itself — so the two archives are the
//  same shape byte for byte and either side opens the other's.
//
//  One session → a save panel for `<id>.daisysession`. Several → a
//  folder to put them in, one archive each, named by session id.
//

import AppKit
import Foundation
import UniformTypeIdentifiers
import os

@MainActor
enum SessionArchiveExporter {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SessionArchiveExport")
    static let contentType = UTType(exportedAs: "com.daisy.session", conformingTo: .zip)

    /// The archive for one session folder, written to `destination`
    /// (replacing what is there).
    nonisolated static func archive(_ directory: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: directory, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: zipURL, to: destination)
            } catch {
                moveError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }
    }

    static func archiveName(for session: StoredSession) -> String {
        session.directoryURL.lastPathComponent + "." + SessionArchiveImporter.fileExtension
    }

    /// The Library's "Export…": one session → save panel; several → a
    /// folder picker. Reports through the toast centre like the audio
    /// export next to it.
    static func export(_ sessions: [StoredSession]) {
        guard !sessions.isEmpty else { return }
        if sessions.count == 1, let session = sessions.first {
            let panel = NSSavePanel()
            panel.title = String(localized: "Export session")
            panel.prompt = String(localized: "Export")
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = archiveName(for: session)
            panel.allowedContentTypes = [contentType]
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            run(pairs: [(session, destination)])
        } else {
            let panel = NSOpenPanel()
            panel.title = String(localized: "Export \(sessions.count) sessions")
            panel.prompt = String(localized: "Export here")
            panel.message = String(localized: "Each session becomes its own .daisysession file in this folder.")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            run(pairs: sessions.map { ($0, folder.appendingPathComponent(archiveName(for: $0))) })
        }
    }

    private static func run(pairs: [(StoredSession, URL)]) {
        let jobs = pairs.map { ($0.0.directoryURL, $0.1) }
        ToastCenter.shared.show(
            jobs.count == 1 ? String(localized: "Exporting session") : String(localized: "Exporting \(jobs.count) sessions"),
            style: .info
        )
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for (directory, destination) in jobs {
                do {
                    try archive(directory, to: destination)
                } catch {
                    failures.append("\(directory.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let done = jobs.count - failures.count
            await MainActor.run {
                if failures.isEmpty {
                    ToastCenter.shared.show(
                        done == 1 ? String(localized: "Session exported") : String(localized: "\(done) sessions exported"),
                        style: .success
                    )
                    if let only = jobs.count == 1 ? jobs.first?.1 : nil {
                        NSWorkspace.shared.activateFileViewerSelecting([only])
                    }
                } else {
                    log.error("Export failed: \(failures.joined(separator: "; "), privacy: .public)")
                    ToastCenter.shared.show(
                        String(localized: "\(done) exported, \(failures.count) failed: \(failures.joined(separator: "; "))"),
                        style: .error
                    )
                }
            }
        }
    }
}
