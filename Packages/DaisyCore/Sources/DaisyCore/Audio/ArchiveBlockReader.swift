//
//  ArchiveBlockReader.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/AudioConverter.swift (macOS Daisy
//  1.0.7.72, `ArchiveBlockReader` + `CAFPartPuller`, 2026-09-21) for
//  backlog 9 H-0. Streams a `.caf` archive (one or more part files) as
//  fixed-length 16 kHz mono Float32 blocks instead of one session-sized
//  array: memory depends on the block, not on the meeting. The field
//  day's 86-minute recording decoded whole peaked at 1.8 GB; a three-hour
//  meeting would be jetsam.
//
//  Boundary rule — never cut mid-word: after the target block length,
//  keep reading up to `cutSearchSeconds` more and cut at the CENTER of
//  the quietest `minQuietSeconds` run in that window (lowest summed
//  energy over 100 ms sub-windows). No threshold to tune: on normal
//  speech this lands in an inter-utterance pause. The remainder past the
//  cut is carried as the head of the next block, across `.partN.caf`
//  boundaries too. Blocks are contiguous and non-overlapping:
//  concatenating them reproduces `Resampler.decodeToMono16k` exactly.
//
//  Concurrency: driven strictly serially (one `nextBlock()` at a time
//  from one detached task, awaited before the next); `@unchecked
//  Sendable` only so the instance can cross the `Task.detached` hop.
//

import AVFoundation
import Foundation
import os

public nonisolated final class ArchiveBlockReader: @unchecked Sendable {
    public static let sampleRate = 16_000
    private static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "ArchiveBlockReader")

    private let urls: [URL]
    private let targetSamples: Int
    private let searchSamples: Int
    private let quietRunSamples: Int
    private let outFormat: AVAudioFormat?

    private var fileIndex = 0
    private var puller: CAFPartPuller?
    private var carry: [Float] = []
    private var yieldedSamples = 0
    private var exhausted = false

    /// Parts that couldn't be opened during this read. Non-empty means
    /// the output has a hole in it and every timestamp after that hole
    /// is earlier than the real one.
    public private(set) var skippedParts: [URL] = []
    /// Parts that opened and held no audio at all.
    public private(set) var emptyParts: [URL] = []

    public init(urls: [URL],
                blockSeconds: Double = 600,
                cutSearchSeconds: Double = 60,
                minQuietSeconds: Double = 0.4)
    {
        self.urls = urls
        self.targetSamples = Int(blockSeconds * Double(Self.sampleRate))
        self.searchSamples = Int(cutSearchSeconds * Double(Self.sampleRate))
        self.quietRunSamples = Int(minQuietSeconds * Double(Self.sampleRate))
        self.outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )
    }

    /// Next block of decoded audio, or `nil` when the archive is fully
    /// consumed. `startSec` is the block's offset from the start of the
    /// archive.
    public func nextBlock() -> (samples: [Float], startSec: Double)? {
        guard let outFormat else { return nil }
        var buf = carry
        carry = []

        let fillLimit = targetSamples + searchSamples
        while !exhausted && buf.count < fillLimit {
            if puller == nil {
                if fileIndex >= urls.count { exhausted = true; break }
                let url = urls[fileIndex]
                fileIndex += 1
                // A part that opens and holds no frames is empty, not
                // missing: the caller finishes an empty recording as
                // such instead of failing it forever (24.09).
                if FileManager.default.fileExists(atPath: url.path),
                   let file = try? AVAudioFile(forReading: url), file.length == 0 {
                    emptyParts.append(url)
                    continue
                }
                guard FileManager.default.fileExists(atPath: url.path),
                      let next = CAFPartPuller(url: url, out: outFormat) else {
                    skippedParts.append(url)
                    Self.log.error("Part \(url.lastPathComponent, privacy: .public) could not be opened — its audio is missing from this pass and everything after it shifts earlier")
                    continue
                }
                puller = next
            }
            if let chunk = puller?.nextChunk() {
                buf.append(contentsOf: chunk)
            } else {
                puller = nil
            }
        }

        guard !buf.isEmpty else { return nil }
        let startSec = Double(yieldedSamples) / Double(Self.sampleRate)
        let cut: Int = exhausted ? buf.count : quietestCut(in: buf)
        let block = Array(buf[0..<cut])
        if cut < buf.count {
            carry = Array(buf[cut...])
        }
        yieldedSamples += cut
        return (block, startSec)
    }

    /// Index of the seam: center of the quietest `quietRunSamples` run
    /// inside `[targetSamples, buf.count)`, scanned in 100 ms sub-windows
    /// by summed energy.
    private func quietestCut(in buf: [Float]) -> Int {
        let windowSamples = Self.sampleRate / 10
        let runWindows = max(1, quietRunSamples / windowSamples)
        let searchStart = targetSamples
        let searchEnd = min(buf.count, targetSamples + searchSamples)
        let windowCount = (searchEnd - searchStart) / windowSamples
        guard windowCount > runWindows else { return min(searchEnd, targetSamples) }

        var energies: [Float] = []
        energies.reserveCapacity(windowCount)
        buf.withUnsafeBufferPointer { p in
            for w in 0..<windowCount {
                let base = searchStart + w * windowSamples
                var sum: Float = 0
                for i in base..<(base + windowSamples) {
                    let x = p[i]
                    sum += x * x
                }
                energies.append(sum)
            }
        }

        var runSum: Float = 0
        for w in 0..<runWindows { runSum += energies[w] }
        var bestSum = runSum
        var bestStart = 0
        for w in runWindows..<windowCount {
            runSum += energies[w] - energies[w - runWindows]
            if runSum < bestSum {
                bestSum = runSum
                bestStart = w - runWindows + 1
            }
        }
        return searchStart + (bestStart + runWindows / 2) * windowSamples
    }
}

/// One `.caf` part decoded incrementally: each `nextChunk()` performs a
/// single `AVAudioConverter` pull (~10 s of native-rate input) and
/// returns its 16 kHz mono output.
nonisolated private final class CAFPartPuller {
    private let converter: AVAudioConverter
    private let feed: FileFeed
    private let outFormat: AVAudioFormat
    private let outCap: AVAudioFrameCount
    private var done = false

    init?(url: URL, out: AVAudioFormat) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        guard file.length > 0, inFormat.sampleRate > 0,
              let conv = AVAudioConverter(from: inFormat, to: out) else { return nil }
        let inBlock = AVAudioFrameCount(max(inFormat.sampleRate, 16_000) * 10)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inBlock) else { return nil }
        self.converter = conv
        self.outFormat = out
        self.feed = FileFeed(file: file, inBuf: inBuf, blockFrames: inBlock)
        let ratio = out.sampleRate / inFormat.sampleRate
        self.outCap = AVAudioFrameCount(Double(inBlock) * ratio + 1024)
    }

    /// `nil` == part fully consumed. May return an empty chunk mid-file
    /// (resampler priming) — callers just keep pulling.
    func nextChunk() -> [Float]? {
        if done { return nil }
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
            done = true
            return nil
        }
        let feed = self.feed
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
            if let buf = feed.readNext() {
                inStatus.pointee = .haveData
                return buf
            }
            inStatus.pointee = .endOfStream
            return nil
        }
        var chunk: [Float] = []
        if let ch = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
            chunk = Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
        }
        if status == .error || status == .endOfStream {
            done = true
            if chunk.isEmpty { return nil }
        }
        return chunk
    }
}
