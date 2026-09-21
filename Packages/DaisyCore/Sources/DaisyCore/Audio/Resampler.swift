//
//  Resampler.swift
//  DaisyCore
//
//  Native-rate audio → 16 kHz mono Float32, the one input every engine
//  takes. Adapted from daisy-app/Daisy/AudioConverter.swift
//  (`AudioArchiveDecoder.decodeToMono16k` / `decodeFile` /
//  `CAFDecodeFeed`, macOS Daisy 1.0.7.72, 2026-09-19): the file path is
//  the Mac's stream-decode in ~10 s blocks (only the 16 kHz result grows
//  in memory); the buffer path is new — the recorder hands live
//  `AVAudioPCMBuffer`s here when a future live mode needs them.
//
//  Microphone audio is archived at the device's REAL rate and channel
//  count (session-format.md §2.1); resampling happens here, at
//  transcription time, never on the capture path.
//

import AVFoundation
import Foundation

public nonisolated enum Resampler {
    public static let targetSampleRate: Double = 16_000

    /// The one output format.
    public static var outputFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// Decode one or more audio files to a single 16 kHz mono Float32
    /// array, concatenated in the given order. Each file is converted
    /// independently — `.partN.caf` files may carry different native
    /// formats. Missing / unreadable / zero-frame parts are skipped.
    /// Returns `nil` only when NOTHING decoded.
    public static func decodeToMono16k(urls: [URL]) -> [Float]? {
        guard !urls.isEmpty, let out = outputFormat else { return nil }
        var samples: [Float] = []
        var anyDecoded = false
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let part = decodeFile(url: url, to: out), !part.isEmpty else { continue }
            samples.append(contentsOf: part)
            anyDecoded = true
        }
        return anyDecoded ? samples : nil
    }

    /// Convert one in-memory buffer (any PCM format) to 16 kHz mono.
    public static func resample(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let out = outputFormat else { return [] }
        let inFormat = buffer.format
        if inFormat.sampleRate == out.sampleRate, inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32, !inFormat.isInterleaved,
           let ch = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: inFormat, to: out) else { return [] }
        let ratio = out.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCap) else { return [] }
        let feed = SingleBufferFeed(buffer: buffer)
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
            if let b = feed.take() {
                inStatus.pointee = .haveData
                return b
            }
            inStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Stream-decode a single file in ~10 s blocks. Empty array for a
    /// zero-frame file, `nil` on a hard open/convert failure.
    public static func decodeFile(url: URL, to out: AVAudioFormat) -> [Float]? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }
        let inFormat = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, inFormat.sampleRate > 0 else { return [] }
        guard let converter = AVAudioConverter(from: inFormat, to: out) else { return nil }

        let inBlock = AVAudioFrameCount(max(inFormat.sampleRate, 16_000) * 10)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inBlock) else { return nil }
        let feed = FileFeed(file: file, inBuf: inBuf, blockFrames: inBlock)

        var result: [Float] = []
        result.reserveCapacity(Int(Double(totalFrames) * out.sampleRate / inFormat.sampleRate) + 1024)

        let ratio = out.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBlock) * ratio + 1024)

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCap) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                if let buf = feed.readNext() {
                    inStatus.pointee = .haveData
                    return buf
                }
                inStatus.pointee = .endOfStream
                return nil
            }
            if let ch = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            }
            if status == .error || status == .endOfStream { break }
        }
        return result
    }
}

/// AVAudioConverter's input block is `@Sendable`; hand it ONE
/// `@unchecked Sendable` box. AVFoundation calls the block synchronously
/// on the converting thread for the lifetime of each `convert()`, so
/// there is no real concurrent access.
nonisolated final class FileFeed: @unchecked Sendable {
    private let file: AVAudioFile
    private let inBuf: AVAudioPCMBuffer
    private let blockFrames: AVAudioFrameCount

    init(file: AVAudioFile, inBuf: AVAudioPCMBuffer, blockFrames: AVAudioFrameCount) {
        self.file = file
        self.inBuf = inBuf
        self.blockFrames = blockFrames
    }

    func readNext() -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        do {
            try file.read(into: inBuf, frameCount: blockFrames)
        } catch {
            return nil
        }
        return inBuf.frameLength > 0 ? inBuf : nil
    }
}

private nonisolated final class SingleBufferFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
