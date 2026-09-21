//
//  ResamplerTests.swift
//  DaisyCoreTests
//
//  N-2 DoD: a 440 Hz sine at 48 kHz → 16 kHz keeps its length (÷3) and
//  its peak. Plus the Whisper segment mapping over synthetic segments.
//

import Testing
import Foundation
import AVFoundation
@testable import DaisyCore

@Suite("Resampler")
struct ResamplerTests {
    private func sine(rate: Double, seconds: Double, hz: Double, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(channels) {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = Float(sin(2 * .pi * hz * Double(i) / rate))
            }
        }
        return buf
    }

    @Test func sine48kTo16kKeepsLengthAndPeak() {
        let input = sine(rate: 48_000, seconds: 2, hz: 440)
        let out = Resampler.resample(buffer: input)
        #expect(abs(out.count - 32_000) <= 64)
        let peak = out.map { abs($0) }.max() ?? 0
        #expect(peak > 0.95 && peak < 1.05)
        // Zero crossings ≈ 2 × 440 × 2 s = 1760 (± edge effects).
        var crossings = 0
        for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { crossings += 1 }
        #expect(abs(crossings - 1760) < 40)
    }

    @Test func stereo44kFileDecodesToMono16k() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resampler-\(UUID().uuidString).caf")
        let input = sine(rate: 44_100, seconds: 1.5, hz: 440, channels: 2)
        let file = try AVAudioFile(forWriting: url, settings: input.format.settings)
        try file.write(from: input)
        if #available(macOS 15, *) { file.close() }
        let samples = try #require(Resampler.decodeToMono16k(urls: [url]))
        #expect(abs(samples.count - 24_000) <= 64, "got \(samples.count)")
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.95 && peak < 1.05)
        // A missing part is skipped, an all-missing list is nil.
        #expect(Resampler.decodeToMono16k(urls: [url, url.appendingPathExtension("missing")])?.count == samples.count)
        #expect(Resampler.decodeToMono16k(urls: [url.appendingPathExtension("missing")]) == nil)
    }

    @Test func whisperSegmentsAreSortedTrimmedAndDeduplicated() {
        let origin = Date()
        let raw: [WhisperEngine.RawSegment] = [
            .init(start: 3.0, end: 3.6, text: " Next one"),
            .init(start: 0.5, end: 1.4, text: " Hello world "),
            .init(start: 1.5, end: 1.6, text: "   "),
            .init(start: 3.7, end: 4.0, text: "Next one"),   // Whisper's loop — dropped
        ]
        let segs = WhisperEngine.segments(from: raw, origin: origin)
        #expect(segs.map(\.text) == ["Hello world", "Next one"])
        #expect(segs[0].startSec == 0.5 && segs[0].endSec == 1.4)
        #expect(segs[1].startSec == 3.0)
        #expect(segs[0].startedAt == origin.addingTimeInterval(0.5))
        #expect(WhisperEngine.segments(from: [], origin: origin).isEmpty)
    }
}

@Suite("LanguageDetector")
struct LanguageDetectorTests {
    @Test func russianTextIsRussianWhateverWhisperSaid() {
        #expect(LanguageDetector.detect("Ох, жди цапи, что там делают... Гигиена утренняя очень важна всем. Ну подкаст...") == "ru")
        #expect(LanguageDetector.detect("Let us talk about the quarterly numbers and the roadmap for next year.") == "en")
        #expect(LanguageDetector.detect("ok") == nil)
    }
}

@Suite("ArchiveBlockReader")
struct ArchiveBlockReaderTests {
    /// Blocks concatenated == the whole-file decode, sample for sample;
    /// the seam sits inside the quiet gap, not in the tone.
    @Test func blocksReproduceTheWholeDecodeAndCutInTheQuiet() throws {
        let rate = 48_000.0
        let seconds = 30.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            // Tone everywhere except a 2-second silence at 11–13 s.
            let quiet = t >= 11 && t < 13
            ch[i] = quiet ? 0 : Float(0.5 * sin(2 * .pi * 440 * t))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blocks-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
        if #available(macOS 15, *) { file.close() }
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try #require(Resampler.decodeToMono16k(urls: [url]))
        // Target 10 s, search up to 5 s more → the seam must land in 11–13 s.
        let reader = ArchiveBlockReader(urls: [url], blockSeconds: 10, cutSearchSeconds: 5, minQuietSeconds: 0.4)
        var joined: [Float] = []
        var starts: [Double] = []
        while let block = reader.nextBlock() {
            starts.append(block.startSec)
            joined.append(contentsOf: block.samples)
        }
        #expect(joined == whole)
        #expect(starts.first == 0)
        #expect(starts.count >= 2)
        let seam = starts[1]
        #expect(seam > 11 && seam < 13, "seam at \(seam) s should be inside the 11–13 s silence")
        #expect(reader.skippedParts.isEmpty)
    }
}
