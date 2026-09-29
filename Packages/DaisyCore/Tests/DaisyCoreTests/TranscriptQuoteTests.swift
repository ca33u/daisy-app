//
//  TranscriptQuoteTests.swift
//  DaisyCoreTests
//
//  Backlog 24 М-11: the lines a selection touches, and a quote's audio
//  mixed from two sources (the Mac's microphone and system audio).
//

import AVFoundation
import Foundation
import Testing
@testable import DaisyCore

@Suite("Transcript quote")
struct TranscriptQuoteTests {
    private let lines = [
        TranscriptTimeline.Segment(startSec: 5, speaker: "Anna", text: "Morning.", rawLine: ""),
        TranscriptTimeline.Segment(startSec: 12, speaker: "Boris", text: "The price is ==2400==, final.", rawLine: ""),
        TranscriptTimeline.Segment(startSec: 20, speaker: "Anna", text: "Deal, send the contract.", rawLine: ""),
        TranscriptTimeline.Segment(startSec: 31, speaker: "Boris", text: "Tomorrow.", rawLine: ""),
    ]

    @Test func aSelectionFromTheMiddleOfOneLineToAnotherTakesBothLines() {
        let chosen = TranscriptQuote.segments(touchedBy: "price is 2400, final.\n[0:20 · Anna] Deal, send", in: lines)
        #expect(chosen.map(\.startSec) == [12, 20])
        #expect(TranscriptQuote.segments(touchedBy: "zz", in: lines).isEmpty)
    }

    @Test func twoSourcesAreMixedIntoOneCut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func tone(_ name: String, seconds: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(16_000 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
            try file.write(from: buffer)
            return url
        }
        let out = dir.appendingPathComponent("quote.m4a")
        try await TranscriptQuote.exportAudio(tracks: [[try tone("microphone.caf", seconds: 6)], [try tone("system_audio.caf", seconds: 8)]],
                                              range: 2...7, to: out)
        let length = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(length - 5) < 0.2)
    }
}
