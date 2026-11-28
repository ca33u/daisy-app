// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SessionFolderPlacement.swift
//  Daisy
//
//  Where a new recording's folder goes, and what happens when it can't
//  go there.
//
//  Up to and including 1.0.8.54 a folder that couldn't be created was one line in the
//  log. The recording went on with nowhere to write: no audio, no
//  transcript, and at Stop the «finished» sound (found 23.11 reading the
//  code beside Superwhisper's 3.4.0 notes; no report of it). The base
//  opening was taken for proof that it could be written, and it isn't: a
//  security scope is handed out for a read-only volume, a folder can hold
//  a file where `Daisy` should go, a share can drop between the two.
//
//  So the folder is made and a file is written into it. When the folder
//  the person picked doesn't take it, the recording goes to Daisy's own
//  folder, which the Library lists beside it, and the person is told.
//  When that fails too there is nowhere to record, and the caller refuses
//  to start.
//

import Foundation
import os

@MainActor
enum SessionFolderPlacement {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SessionsFolder")

    struct Placed {
        let directory: URL
        /// Held by the recording until its last write.
        let ticket: SessionsFolder.AccessTicket
        /// The person picked a folder and the recording is not in it.
        let missedPickedFolder: Bool
    }

    struct NoPlace: LocalizedError, Equatable {
        /// Neither folder took the recording and a full disk is why.
        var outOfSpace = false

        var errorDescription: String? {
            outOfSpace
                ? String(localized: "No space on the disk for a recording")
                : String(localized: "Daisy can’t write to the recordings folder")
        }
    }

    /// The folder for a recording starting now.
    ///
    /// `checksWrite` — write a file into it to see that it takes one. Off
    /// for a dictation: its folder is deleted when it ends, and on a share
    /// the check is two round trips between the key and the microphone.
    static func place(stamp: String, checksWrite: Bool) throws -> Placed {
        try place(stamp: stamp, checksWrite: checksWrite, hasPickedFolder: SessionsFolder.hasUserFolder,
                  picked: { SessionsFolder.acquireUserBase() },
                  own: { SessionsFolder.acquireDefaultBase() })
    }

    /// - Parameters:
    ///   - stamp: the folder's name; a number is added when it's taken.
    ///   - hasPickedFolder: the person picked a folder, whether or not it
    ///     opens now.
    ///   - picked: access to that folder, nil when there is none or it
    ///     doesn't open.
    ///   - own: access to Daisy's own folder.
    static func place(
        stamp: String, checksWrite: Bool, hasPickedFolder: Bool,
        picked: () -> SessionsFolder.AccessTicket?,
        own: () -> SessionsFolder.AccessTicket?
    ) throws -> Placed {
        var lastError: Error?
        if let ticket = picked() {
            do {
                let directory = try makeDirectory(stamp: stamp, in: ticket.url, checksWrite: checksWrite)
                return Placed(directory: directory, ticket: ticket, missedPickedFolder: false)
            } catch {
                ticket.release()
                lastError = error
                log.error("The picked folder didn't take a recording: \(error.localizedDescription, privacy: .private)")
            }
        }
        if let ticket = own() {
            do {
                let directory = try makeDirectory(stamp: stamp, in: ticket.url, checksWrite: checksWrite)
                return Placed(directory: directory, ticket: ticket, missedPickedFolder: hasPickedFolder)
            } catch {
                ticket.release()
                lastError = error
                log.error("Daisy's own folder didn't take a recording: \(error.localizedDescription, privacy: .private)")
            }
        }
        throw NoPlace(outOfSpace: lastError.map(isOutOfSpace) ?? false)
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        return error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOSPC) || error.code == Int(EDQUOT))
    }

    private static func makeDirectory(stamp: String, in base: URL, checksWrite: Bool) throws -> URL {
        let fm = FileManager.default
        let root = SessionsFolder.sessionsDirectory(in: base)
        // Named by the second, so two sessions started within one — a
        // dictation over a recording that began a moment ago, a rotation —
        // must not share a folder: the dictation's teardown deletes its
        // folder, which would take the recording with it (review 31.10).
        // No await between the check and the create, so on the main actor
        // nothing can claim the name in between.
        var directory = root.appendingPathComponent(stamp, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard checksWrite else { return directory }
        let probe = directory.appendingPathComponent(".write-check")
        do {
            try Data([0]).write(to: probe)
            // A share that lets nothing be deleted still takes a recording.
            try? fm.removeItem(at: probe)
        } catch {
            // Made a moment ago by this call, and nothing of the person's
            // is in it.
            try? fm.removeItem(at: directory)
            throw error
        }
        return directory
    }
}
