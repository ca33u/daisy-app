//
//  SessionArchiveImportTests.swift
//  DaisyTests
//
//  backlog 4, part C: a `.daisysession` from the iPhone lands in
//  Sessions as the session folder it already is — same ID, transcript
//  and audio intact — and the Library sees a valid session with
//  retained audio, which is what diarization / "Transcribe again" need
//  (checked by hand on 2026-09-19, locked here).
//

import Foundation
import Testing
@testable import Daisy

@Suite("iPhone session archive import")
struct SessionArchiveImportTests {

    private func makeDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A phone session: transcript.md with `daisy_origin: iphone`, a
    /// microphone.caf big enough to count as retained audio.
    private func makePhoneSession(in parent: URL, id: String) throws -> URL {
        let dir = parent.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = """
        ---
        title: "Field test"
        type: meeting-transcript
        source: Daisy
        locale: auto
        started: 2026-09-19T08:00:00Z
        duration_sec: 61
        daisy_folder: inbox
        daisy_kind: recording
        daisy_origin: iphone
        daisy_speaker_map: {}
        daisy_system_audio_status: off
        daisy_mic_audio_status: captured (200000 B)
        tags: [meeting, transcript, daisy]
        ---

        # Field test

        ## Transcript

        **[0:00 · Egor]** hello from the phone
        """
        try Data(transcript.utf8).write(to: dir.appendingPathComponent("transcript.md"))
        try Data(count: 200_000).write(to: dir.appendingPathComponent("microphone.caf"))
        return dir
    }

    private func zip(_ folder: URL, to archive: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test("Archive unpacks into Sessions under its own ID, transcript and audio intact")
    func importKeepsIDAndContents() throws {
        let scratch = try makeDir("daisysession-src")
        let sessions = try makeDir("daisysession-dst")
        defer { try? FileManager.default.removeItem(at: scratch); try? FileManager.default.removeItem(at: sessions) }
        let id = "2026-09-19T08-00-00Z"
        let folder = try makePhoneSession(in: scratch, id: id)
        let archive = scratch.appendingPathComponent("\(id).daisysession")
        try zip(folder, to: archive)

        let imported = try SessionArchiveImporter.importArchive(archive, into: sessions)
        #expect(imported.lastPathComponent == id)
        #expect(FileManager.default.fileExists(atPath: imported.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: imported.appendingPathComponent("microphone.caf").path))

        // What the Library and the re-transcription sheet check.
        guard case .valid = SessionStore.classify(directory: imported) else {
            Issue.record("An imported phone session must classify as valid")
            return
        }
        #expect(SessionAudioFiles.discover(in: imported).hasAny)
        #expect(SessionAudioFiles.discover(in: imported).microphone.map(\.lastPathComponent) == ["microphone.caf"])
    }

    @Test("A second import of the same ID gets a -2 suffix, never overwrites")
    func importNeverOverwrites() throws {
        let scratch = try makeDir("daisysession-src")
        let sessions = try makeDir("daisysession-dst")
        defer { try? FileManager.default.removeItem(at: scratch); try? FileManager.default.removeItem(at: sessions) }
        let id = "2026-09-19T09-00-00Z"
        let folder = try makePhoneSession(in: scratch, id: id)
        let archive = scratch.appendingPathComponent("\(id).daisysession")
        try zip(folder, to: archive)

        let first = try SessionArchiveImporter.importArchive(archive, into: sessions)
        let second = try SessionArchiveImporter.importArchive(archive, into: sessions)
        #expect(first.lastPathComponent == id)
        #expect(second.lastPathComponent == "\(id)-2")
    }

    @Test("A zip with no transcript and no audio is refused")
    func emptyArchiveIsRefused() throws {
        let scratch = try makeDir("daisysession-src")
        let sessions = try makeDir("daisysession-dst")
        defer { try? FileManager.default.removeItem(at: scratch); try? FileManager.default.removeItem(at: sessions) }
        let folder = scratch.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let archive = scratch.appendingPathComponent("junk.daisysession")
        try zip(folder, to: archive)

        #expect(throws: SessionArchiveImporter.ImportError.self) {
            try SessionArchiveImporter.importArchive(archive, into: sessions)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sessions.path))?.isEmpty ?? true)
    }
}
