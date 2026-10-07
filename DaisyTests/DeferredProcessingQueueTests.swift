//
//  DeferredProcessingQueueTests.swift
//  DaisyTests
//
//  «Process later, on a charger» adds `waitsForPower` to queue jobs. A
//  queue file written before it must still load — a job lost to a
//  decode failure is a meeting that never gets its final pass.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Deferred processing queue")
struct DeferredProcessingQueueTests {
    private func decode(_ json: String) throws -> [ImportTranscriptionJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ImportTranscriptionJob].self, from: Data(json.utf8))
    }

    @Test("a queue file from before the power wait still loads")
    func oldFileLoads() throws {
        let jobs = try decode("""
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sessionID":"s","directoryPath":"/tmp/s",
          "title":"t","modelID":"m","language":"auto","diarize":true,
          "createdAt":"2026-10-01T10:00:00Z","attempts":0,"finishesLiveTranscript":true}]
        """)
        #expect(jobs.count == 1)
        #expect(jobs[0].waitsForPower == nil)
    }

    @Test("the power wait round-trips")
    func roundTrip() throws {
        let job = ImportTranscriptionJob(
            id: UUID(), sessionID: "s", directoryPath: "/tmp/s", title: "t",
            modelID: "m", language: "auto", diarize: true, notBefore: nil,
            createdAt: Date(timeIntervalSince1970: 0), attempts: 0, lastError: nil,
            finishesLiveTranscript: true, waitsForPower: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try decode(String(decoding: try encoder.encode([job]), as: UTF8.self))
        #expect(back.first?.waitsForPower == true)
    }

    @Test("renaming or moving a waiting meeting is not an edit; changing its text is")
    @MainActor
    func bodyHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcript.md")
        try "---\ntitle: \"A\"\n---\n\n**[0:05 · Me]** Hello.\n".write(to: url, atomically: true, encoding: .utf8)
        let queued = ImportTranscriptionQueue.transcriptBodyHash(in: dir)
        try "---\ntitle: \"Renamed\"\ndaisy_folder: work\n---\n\n**[0:05 · Me]** Hello.\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(ImportTranscriptionQueue.transcriptBodyHash(in: dir) == queued)
        try "---\ntitle: \"Renamed\"\n---\n\n**[0:05 · Me]** Hello, edited.\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(ImportTranscriptionQueue.transcriptBodyHash(in: dir) != queued)
    }
}
