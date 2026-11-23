//
//  SessionFolderPlacementTests.swift
//  DaisyTests
//
//  A recording always has a folder that takes files, or doesn't start
//  (`SessionFolderPlacement`). Everything happens under a temporary
//  directory; the person's folder and Daisy's own are never touched.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct SessionFolderPlacementTests {
    private let stamp = "2026-11-23T10-00-00Z"

    private func withBases(_ body: (_ picked: URL, _ own: URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("daisy-placement-\(UUID().uuidString)", isDirectory: true)
        let picked = root.appendingPathComponent("picked", isDirectory: true)
        let own = root.appendingPathComponent("own", isDirectory: true)
        try fm.createDirectory(at: picked, withIntermediateDirectories: true)
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(picked, own)
    }

    /// The same access check the recorder makes.
    private func access(_ url: URL) -> SessionsFolder.AccessTicket? {
        SessionsFolder.acquireAccess(to: url, requireWrite: true)
    }

    private func entries(_ base: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: SessionsFolder.sessionsDirectory(in: base).path)) ?? []
    }

    private func place(picked: URL?, own: URL?, hasPickedFolder: Bool, checksWrite: Bool = true) throws -> SessionFolderPlacement.Placed {
        try SessionFolderPlacement.place(
            stamp: stamp, checksWrite: checksWrite, hasPickedFolder: hasPickedFolder,
            picked: { picked.flatMap(access) }, own: { own.flatMap(access) }
        )
    }

    @Test func thePickedFolderTakesTheRecording() throws {
        try withBases { picked, own in
            let placed = try place(picked: picked, own: own, hasPickedFolder: true)
            #expect(placed.directory.path.hasPrefix(picked.path))
            #expect(!placed.missedPickedFolder)
            #expect(entries(own).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: placed.directory.path).isEmpty)
        }
    }

    @Test func withNoPickedFolderDaisysOwnIsNotAMiss() throws {
        try withBases { _, own in
            let placed = try place(picked: nil, own: own, hasPickedFolder: false)
            #expect(placed.directory.path.hasPrefix(own.path))
            #expect(!placed.missedPickedFolder)
        }
    }

    /// The loss itself: the base opens and reads as writable, and the
    /// session folder still can't be made in it.
    @Test func aFileWhereTheFolderGoesSendsTheRecordingToDaisysOwn() throws {
        try withBases { picked, own in
            try Data("x".utf8).write(to: picked.appendingPathComponent("Daisy"))
            #expect(access(picked) != nil)
            let placed = try place(picked: picked, own: own, hasPickedFolder: true)
            #expect(placed.directory.path.hasPrefix(own.path))
            #expect(placed.missedPickedFolder)
        }
    }

    /// `Daisy/Sessions` that can be read and not written. Root writes past
    /// the mode bits.
    @Test(.enabled(if: geteuid() != 0)) func aReadOnlySessionsFolderSendsTheRecordingToDaisysOwn() throws {
        try withBases { picked, own in
            let sessions = SessionsFolder.sessionsDirectory(in: picked)
            let fm = FileManager.default
            try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessions.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path) }
            #expect(access(picked) != nil)
            let placed = try place(picked: picked, own: own, hasPickedFolder: true)
            #expect(placed.directory.path.hasPrefix(own.path))
            #expect(placed.missedPickedFolder)
            #expect(entries(picked).isEmpty)
        }
    }

    /// A folder can be made and a file can't: only writing one tells. The
    /// empty folder is taken back.
    @Test(.enabled(if: geteuid() != 0)) func aFolderThatTakesNoFilesSendsTheRecordingToDaisysOwn() throws {
        try withBases { picked, own in
            let sessions = SessionsFolder.sessionsDirectory(in: picked)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", "everyone deny add_file,file_inherit,directory_inherit", sessions.path]
            try chmod.run()
            chmod.waitUntilExit()
            try #require(chmod.terminationStatus == 0)
            let placed = try place(picked: picked, own: own, hasPickedFolder: true)
            #expect(placed.directory.path.hasPrefix(own.path))
            #expect(placed.missedPickedFolder)
            #expect(entries(picked).isEmpty)
            // A dictation doesn't check, and takes the folder as it is.
            let unchecked = try place(picked: picked, own: own, hasPickedFolder: true, checksWrite: false)
            #expect(unchecked.directory.path.hasPrefix(picked.path))
        }
    }

    @Test func aFullDiskIsNamed() {
        #expect(SessionFolderPlacement.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(SessionFolderPlacement.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(!SessionFolderPlacement.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
        #expect(SessionFolderPlacement.NoPlace(outOfSpace: true).localizedDescription
                != SessionFolderPlacement.NoPlace().localizedDescription)
    }

    @Test func aPickedFolderThatDoesNotOpenIsAMiss() throws {
        try withBases { _, own in
            let placed = try place(picked: nil, own: own, hasPickedFolder: true)
            #expect(placed.directory.path.hasPrefix(own.path))
            #expect(placed.missedPickedFolder)
        }
    }

    @Test func nowhereToWriteThrows() throws {
        try withBases { picked, own in
            try Data("x".utf8).write(to: picked.appendingPathComponent("Daisy"))
            try Data("x".utf8).write(to: own.appendingPathComponent("Daisy"))
            #expect(throws: SessionFolderPlacement.NoPlace.self) {
                _ = try place(picked: picked, own: own, hasPickedFolder: true)
            }
            #expect(throws: SessionFolderPlacement.NoPlace.self) {
                _ = try place(picked: nil, own: nil, hasPickedFolder: false)
            }
        }
    }

    @Test func twoRecordingsInOneSecondGetTwoFolders() throws {
        try withBases { picked, own in
            let first = try place(picked: picked, own: own, hasPickedFolder: true)
            let second = try place(picked: picked, own: own, hasPickedFolder: true)
            #expect(first.directory.lastPathComponent == stamp)
            #expect(second.directory.lastPathComponent == "\(stamp)-2")
        }
    }
}
