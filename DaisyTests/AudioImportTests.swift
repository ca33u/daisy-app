//
//  AudioImportTests.swift
//  DaisyTests
//
//  Locks the on-disk contract of audio import (design 2026-08-31, Ф0):
//  the sidecar keeps an imported folder OUT of crash recovery, gives it
//  the file's own title/date/project while there is no transcript, and
//  the Library scan sees non-CAF containers under the session prefixes.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Audio import on disk")
struct AudioImportTests {

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func marker(title: String = "Interview", folder: String = "inbox") -> ImportMarker {
        ImportMarker(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSec: 321,
            folderSlug: folder,
            sourcePath: "/Users/x/Interviews/acme.m4a",
            originalName: "acme.m4a",
            mode: .copy,
            importedAt: Date()
        )
    }

    @Test("Non-CAF containers are discovered under the session prefixes")
    func discover_acceptsImportedContainers() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["system_audio.m4a", "microphone.part2.mp3", "microphone.wav", "notes.m4a", "system_audio.txt"] {
            try Data(count: 16).write(to: dir.appendingPathComponent(name))
        }
        let files = SessionAudioFiles.discover(in: dir)
        #expect(files.system.map(\.lastPathComponent) == ["system_audio.m4a"])
        #expect(files.microphone.map(\.lastPathComponent) == ["microphone.wav", "microphone.part2.mp3"])
    }

    @Test("Imported audio-only folder is valid, not interrupted")
    func classify_importedIsNotInterrupted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Big enough to trip the crash-recovery threshold on its own.
        try Data(count: Int(SessionStore.minRecoverableAudioBytes) + 1)
            .write(to: dir.appendingPathComponent("system_audio.m4a"))

        guard case .interrupted = SessionStore.classify(directory: dir) else {
            Issue.record("Without the sidecar this shape must still be treated as a crashed recording")
            return
        }

        try marker().write(to: dir)
        guard case .valid(let session) = SessionStore.classify(directory: dir) else {
            Issue.record("Imported folder was routed to recovery")
            return
        }
        #expect(session.contentState == .audioOnly)
        #expect(session.transcriptURL == nil)
    }

    @Test("Sidecar supplies title, date, duration and project until a transcript exists")
    func parse_readsSidecar() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 16).write(to: dir.appendingPathComponent("system_audio.m4a"))
        try marker(title: "Acme interview", folder: "interviews").write(to: dir)

        let session = try #require(SessionStore.parseSession(at: dir))
        #expect(session.title == "Acme interview")
        #expect(session.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(session.durationSec == 321)
        #expect(session.folderSlug == "interviews")
        #expect(session.hasSystemAudio)
        #expect(!session.hasMicAudio)
    }

    @Test("Session id follows the recording folder shape and dodges collisions")
    func sessionID_shapeAndCollision() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let first = AudioImporter.uniqueSessionID(for: date, in: dir)
        #expect(first == "2023-11-14T22-13-20Z")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(first), withIntermediateDirectories: true)
        #expect(AudioImporter.uniqueSessionID(for: date, in: dir) == "2023-11-14T22-13-20Z-2")
    }

    @Test("Title comes from the file name with underscores as spaces")
    func title_fromFileName() {
        #expect(AudioImporter.title(fromFileName: "acme_interview-2026-03-12.m4a") == "acme interview-2026-03-12")
        #expect(AudioImporter.title(fromFileName: "  spaced   out .mp3") == "spaced out")
        #expect(AudioImporter.title(fromFileName: "___.wav") == "___")
    }

    @Test("A dropped folder expands one level and names the project")
    func expand_folderOneLevel() throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Interviews", isDirectory: true)
        let sub = folder.appendingPathComponent("day2", isDirectory: true)
        let deep = sub.appendingPathComponent("deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for path in ["b.m4a", "a.mp3", "notes.txt", "day2/c.wav", "day2/deeper/d.wav", "day2/.hidden.m4a"] {
            try Data(count: 4).write(to: folder.appendingPathComponent(path))
        }
        let loose = root.appendingPathComponent("loose.flac")
        try Data(count: 4).write(to: loose)

        let items = AudioImporter.expand([folder, loose])
        #expect(items.map(\.url.lastPathComponent) == ["a.mp3", "b.m4a", "c.wav", "loose.flac"])
        #expect(items.map(\.folderName) == ["Interviews", "Interviews", "Interviews", nil])
    }

    @Test("Only supported containers are importable")
    func canImport_whitelist() {
        #expect(AudioImporter.canImport(URL(fileURLWithPath: "/x/a.M4A")))
        #expect(AudioImporter.canImport(URL(fileURLWithPath: "/x/a.flac")))
        #expect(!AudioImporter.canImport(URL(fileURLWithPath: "/x/a.mkv")))
        #expect(!AudioImporter.canImport(URL(fileURLWithPath: "/x/a")))
    }
}
