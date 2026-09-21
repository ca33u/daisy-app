//
//  SessionArchiveExportTests.swift
//  DaisyTests
//
//  backlog 8 G-3: what the Mac exports, the Mac's own importer opens
//  back — same zip shape as the iPhone's (top-level entry is the folder).
//

import Foundation
import Testing
@testable import Daisy

@Suite("Session archive export")
struct SessionArchiveExportTests {
    @Test("Export → import round trip keeps the id and every file")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "2026-09-21T10-00-00Z"
        let session = root.appendingPathComponent("src/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("screenshots"), withIntermediateDirectories: true)
        try "---\ntitle: \"T\"\ndaisy_kind: recording\ndaisy_speaker_map: {}\n---\n\n# T\n\n## Transcript\n\n**[0:00 · Me]** hi\n".write(to: session.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Data(repeating: 7, count: 4096).write(to: session.appendingPathComponent("microphone.caf"))
        try Data([0xFF, 0xD8]).write(to: session.appendingPathComponent("screenshots/001.jpg"))
        try "{\"001.jpg\":12.0}".write(to: session.appendingPathComponent("screenshots/index.json"), atomically: true, encoding: .utf8)

        let archive = root.appendingPathComponent("out/\(id).daisysession")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionArchiveExporter.archive(session, to: archive)
        #expect(SessionArchiveImporter.isSessionArchive(archive))
        #expect((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0)

        // The top-level entry must be the folder itself — what the importer
        // (and the iPhone's archiver) expect.
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", archive.path]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        listing.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(entries.contains("\(id)/transcript.md"))
        #expect(entries.contains("\(id)/screenshots/index.json"))
        #expect(entries.allSatisfy { $0.hasPrefix(id + "/") })

        let sessions = root.appendingPathComponent("lib/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let imported = try SessionArchiveImporter.importArchive(archive, into: sessions)
        #expect(imported.lastPathComponent == id)
        #expect(try Data(contentsOf: imported.appendingPathComponent("microphone.caf")).count == 4096)
        #expect(FileManager.default.fileExists(atPath: imported.appendingPathComponent("screenshots/001.jpg").path))
    }
}
