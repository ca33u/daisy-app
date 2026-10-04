//
//  ZipArchiveTests.swift
//  DaisyCoreTests
//
//  backlog 8 G-3: what `NSFileCoordinator(.forUploading)` zips (the Mac's
//  and the phone's exporter), `ZipArchive` unpacks back, byte for byte.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("ZipArchive")
struct ZipArchiveTests {
    @Test func coordinatorZipRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "2026-09-21T10-00-00Z"
        let session = root.appendingPathComponent("src/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("screenshots"), withIntermediateDirectories: true)
        let transcript = "---\ntitle: \"T\"\n---\n\n# T\n\n## Transcript\n\n**[0:00 · Me]** привет\n"
        try transcript.write(to: session.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        var audio = Data(count: 200_000)
        for i in 0..<audio.count { audio[i] = UInt8(truncatingIfNeeded: i &* 31) }   // incompressible-ish
        try audio.write(to: session.appendingPathComponent("microphone.caf"))
        try Data(repeating: 0, count: 50_000).write(to: session.appendingPathComponent("screenshots/001.jpg"))   // deflates hard
        try "{\"001.jpg\":12.0}".write(to: session.appendingPathComponent("screenshots/index.json"), atomically: true, encoding: .utf8)

        let archive = root.appendingPathComponent("\(id).daisy")
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: session, options: [.forUploading], error: &coordinatorError) { zip in
            try? FileManager.default.moveItem(at: zip, to: archive)
        }
        #expect(coordinatorError == nil)

        let entries = try ZipArchive.entries(in: try Data(contentsOf: archive))
        #expect(entries.contains { $0.path == "\(id)/transcript.md" })
        let out = root.appendingPathComponent("out", isDirectory: true)
        let top = try ZipArchive.extract(archive, into: out)
        #expect(top == [id])
        #expect(try String(contentsOf: out.appendingPathComponent("\(id)/transcript.md"), encoding: .utf8) == transcript)
        #expect(try Data(contentsOf: out.appendingPathComponent("\(id)/microphone.caf")) == audio)
        #expect(try Data(contentsOf: out.appendingPathComponent("\(id)/screenshots/001.jpg")).count == 50_000)
        #expect(try String(contentsOf: out.appendingPathComponent("\(id)/screenshots/index.json"), encoding: .utf8) == "{\"001.jpg\":12.0}")
    }

    /// Entries larger than the megabyte the extractor works in — one that
    /// barely compresses and one that compresses hard — come back whole.
    @Test func entriesLargerThanAChunkRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipbig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("src/big", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var noisy = Data(count: 3_500_000)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<noisy.count { state = state &* 6364136223846793005 &+ 1442695040888963407; noisy[i] = UInt8(truncatingIfNeeded: state >> 33) }
        try noisy.write(to: folder.appendingPathComponent("noisy.bin"))
        let flat = Data(repeating: 7, count: 5_000_000)
        try flat.write(to: folder.appendingPathComponent("flat.bin"))
        try Data().write(to: folder.appendingPathComponent("empty.bin"))
        let archive = root.appendingPathComponent("big.zip")
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinatorError) { zip in
            try? FileManager.default.moveItem(at: zip, to: archive)
        }
        #expect(coordinatorError == nil)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try ZipArchive.extract(archive, into: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("big/noisy.bin")) == noisy)
        #expect(try Data(contentsOf: out.appendingPathComponent("big/flat.bin")) == flat)
        #expect(try Data(contentsOf: out.appendingPathComponent("big/empty.bin")).isEmpty)
        // Nothing half-written is left beside the files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("big").path).sorted() == ["empty.bin", "flat.bin", "noisy.bin"])
    }

    @Test func junkIsRefused() {
        #expect(throws: ZipArchive.ZipError.self) { try ZipArchive.entries(in: Data("not a zip at all, honestly".utf8)) }
    }
}
