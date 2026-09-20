//
//  ResamplerTests.swift
//  DaisyCoreTests
//
//  N-2 DoD: a 440 Hz sine at 48 kHz → 16 kHz keeps its length (÷3) and
//  its peak. Plus the segmenter over synthetic token timings.
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

    @Test func segmenterSplitsAtPausesAndKeepsWords() {
        let t: [ParakeetEngine.Timing] = [
            .init(token: "▁Hel", start: 0.5, end: 0.7), .init(token: "lo", start: 0.7, end: 0.9),
            .init(token: "▁world", start: 1.0, end: 1.4),
            .init(token: "▁Next", start: 3.0, end: 3.3), .init(token: "▁one", start: 3.4, end: 3.6),
        ]
        let segs = ParakeetEngine.segments(text: "Hello world Next one", timings: t, origin: Date())
        #expect(segs.map(\.text) == ["Hello world", "Next one"])
        #expect(segs[0].startSec == 0.5 && segs[0].endSec == 1.4)
        #expect(segs[1].startSec == 3.0)
        #expect(ParakeetEngine.segments(text: "  ", timings: [], origin: Date()).isEmpty)
        #expect(ParakeetEngine.segments(text: "plain", timings: [], origin: Date()).count == 1)
    }
}
