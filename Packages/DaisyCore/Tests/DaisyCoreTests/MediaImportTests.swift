//
//  MediaImportTests.swift
//  DaisyCoreTests
//
//  backlog 13 М-3: the phone imports media the same way the Mac does —
//  same containers, same refusals, same `import.json`, staging before
//  anything appears in the library (§7.3).
//

import Testing
import AVFoundation
import Foundation
@testable import DaisyCore

@Suite("Importing media (М-3)")
struct MediaImportTests {
    @Test func containersAreAcceptedAndRefusedByName() {
        #expect(MediaImport.canImport(URL(fileURLWithPath: "/tmp/talk.m4a")))
        #expect(MediaImport.canImport(URL(fileURLWithPath: "/tmp/keynote.MP4")))
        #expect(MediaImport.isVideo(URL(fileURLWithPath: "/tmp/keynote.mov")))
        #expect(!MediaImport.canImport(URL(fileURLWithPath: "/tmp/talk.mkv")))
        // A refusal the person can act on, not "unsupported file".
        #expect(MediaImport.rejection(for: URL(fileURLWithPath: "/tmp/talk.mkv"))
                == .containerUnsupported("talk.mkv"))
        #expect(MediaImport.rejection(for: URL(fileURLWithPath: "/tmp/notes.pdf"))
                == .unsupportedType("notes.pdf"))
        #expect(MediaImport.errorText(.containerUnsupported("talk.mkv")).contains("mp4"))
    }

    @Test func titlesComeFromTheFileName() {
        #expect(MediaImport.title(fromFileName: "Interview 2026-03-04.m4a") == "Interview 2026-03-04")
        #expect(MediaImport.title(fromFileName: "board_meeting.mp4") == "board meeting")
        #expect(MediaImport.title(fromFileName: ".m4a") == ".m4a")
    }

    @Test func anAudioFileBecomesASessionWithItsMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SessionsBase(base: root)
        let source = root.appendingPathComponent("Team sync.caf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTone(to: source, seconds: 3)

        let result = try await MediaImport.importFile(source, into: base, folderSlug: "work")
        #expect(result.title == "Team sync")
        #expect(result.durationSec == 3)
        // The audio landed under the name the library scans for.
        let audio = SessionAudioFiles.discover(in: result.directoryURL)
        #expect(audio.system.count == 1)
        #expect(audio.system.first?.lastPathComponent == "system_audio.caf")
        // The marker carries what the session needs until a transcript.
        let marker = try #require(ImportMarker.load(from: result.directoryURL))
        #expect(marker.title == "Team sync")
        #expect(marker.folderSlug == "work")
        #expect(marker.originalName == "Team sync.caf")
        #expect(marker.mode == .copy)          // the phone never moves
        #expect(marker.durationSec == 3)
        // The original is untouched, and no staging is left behind.
        #expect(FileManager.default.fileExists(atPath: source.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.sessionsDirectory.path)
        #expect(!leftovers.contains { $0.hasPrefix(".daisy-import-") })
    }

    @Test func aRefusedFileLeavesNothingBehind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = SessionsBase(base: root)
        let source = root.appendingPathComponent("talk.mkv")
        try Data("not media".utf8).write(to: source)
        await #expect(throws: MediaImportError.containerUnsupported("talk.mkv")) {
            try await MediaImport.importFile(source, into: base)
        }
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: base.sessionsDirectory.path)) ?? []
        #expect(sessions.isEmpty)
    }

    /// The session an import makes must be one the transcription queue
    /// picks up on its own — audio, no transcript (§6).
    @Test func theImportedSessionIsSomethingTheQueueWillTranscribe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = SessionsBase(base: root)
        let source = root.appendingPathComponent("interview.caf")
        try writeTone(to: source, seconds: 2)
        let result = try await MediaImport.importFile(source, into: base)
        let summaries = SessionClassifier.scan(base: base)
        let session = try #require(summaries.first { $0.id == result.sessionID })
        #expect(session.hasAudio)
        #expect(!session.hasTranscript)
        #expect(session.state != .unreadable)
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { channel[i] = Float(sin(2 * .pi * 440 * Double(i) / 16_000) * 0.3) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
