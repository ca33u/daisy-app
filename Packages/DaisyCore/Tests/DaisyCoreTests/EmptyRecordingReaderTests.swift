//
//  EmptyRecordingReaderTests.swift
//  DaisyCoreTests
//
//  24.09: twenty header-only .caf files (a crashed start, instant watch
//  taps) were read as "could not be opened", failed three times, and
//  were queued again by the next scan, forever. An empty part is empty,
//  not missing.
//

import AVFoundation
import Foundation
import Testing
@testable import DaisyCore

@Suite("Block reader: an empty recording is empty, not broken")
struct EmptyRecordingReaderTests {
    @Test func aHeaderOnlyCAFIsEmptyNotSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("microphone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do { _ = try AVAudioFile(forWriting: url, settings: format.settings) }   // closed with no frames

        let reader = ArchiveBlockReader(urls: [url])
        #expect(reader.nextBlock() == nil)
        #expect(reader.emptyParts.map(\.lastPathComponent) == ["microphone.caf"])
        #expect(reader.skippedParts.isEmpty)
    }

    @Test func aMissingPartIsStillSkipped() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).caf")
        let reader = ArchiveBlockReader(urls: [url])
        #expect(reader.nextBlock() == nil)
        #expect(reader.skippedParts.count == 1)
        #expect(reader.emptyParts.isEmpty)
    }
}
