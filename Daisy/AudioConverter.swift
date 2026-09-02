//
//  AudioConverter.swift
//  Daisy
//
//  Wraps AVAudioConverter to turn arbitrary input PCM buffers (any sample
//  rate, any channel count, interleaved or not) into the format Whisper
//  expects: 16 kHz, mono, 32-bit float.
//

import Foundation
import AVFoundation
import os

final class AudioConverter {
    let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.outputFormat = output
        guard let conv = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        self.converter = conv
    }

    /// Convert one input buffer and return the resulting 16 kHz mono Float
    /// samples. Returns nil only on hard converter failure; an empty array
    /// is possible during silence-suppressing rate conversions.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let estimatedOutFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard estimatedOutFrames > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedOutFrames) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            return nil
        }

        guard let ch = outBuffer.floatChannelData?[0] else { return [] }
        let count = Int(outBuffer.frameLength)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: count))
    }
}

/// Decodes finished on-disk `.caf` archives back into the 16 kHz mono
/// Float32 sample array Whisper + FluidAudio expect.
///
/// Why this exists: live transcription runs off an in-memory rolling
/// buffer (`Transcriber.allSamples`) capped at 30 minutes and trimmed
/// when the live pass falls behind on a long/dense recording. The
/// trimmed audio is gone from memory — but it's always on disk in the
/// `.caf` archive, which the recorder writes frame-for-frame for the
/// WHOLE session. The post-Stop final pass decodes the archive here so
/// the saved transcript covers the entire recording regardless of how
/// far live transcription lagged or how much the buffer trimmed.
///
/// `nonisolated` + `enum` (no state) so the decode can run on a
/// background `Task.detached` off the `@MainActor` Transcriber — it's
/// CPU + IO heavy (hundreds of MB on a multi-hour session) and must
/// not block the main thread.
enum AudioArchiveDecoder {
    /// Decode one or more `.caf` archives to a single 16 kHz mono Float32
    /// array, concatenated in the given order. Each file is converted
    /// independently — mid-session route changes roll the mic archive into
    /// `microphone.partN.caf` files that may carry different native formats,
    /// so a single shared converter can't span them. Missing / unreadable /
    /// header-only (zero-frame) parts are skipped. Returns `nil` only when
    /// NOTHING decoded (so the caller can fall back to the in-memory buffer);
    /// a partial decode (one bad part among several good ones) still returns
    /// what was recovered.
    nonisolated static func decodeToMono16k(urls: [URL]) -> [Float]? {
        guard !urls.isEmpty else { return nil }
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,   // Whisper's required input rate
            channels: 1,
            interleaved: false
        ) else { return nil }

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

    /// Write a 16 kHz mono Float32 sample array to a `.caf` at `url`,
    /// overwriting any existing file. Used to materialise a side-note
    /// audio excerpt sliced (and mic+system mixed) out of a meeting's own
    /// archive. Written in 30 s blocks so we never build one giant PCM
    /// buffer. Returns whether the write succeeded.
    @discardableResult
    nonisolated static func writeMono16kCAF(samples: [Float], to url: URL) -> Bool {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ) else { return false }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let block = 16_000 * 30
            var offset = 0
            while offset < samples.count {
                let n = min(block, samples.count - offset)
                guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: AVAudioFrameCount(n)),
                      let ch = buf.floatChannelData?[0] else { return false }
                samples.withUnsafeBufferPointer { src in
                    ch.update(from: src.baseAddress!.advanced(by: offset), count: n)
                }
                buf.frameLength = AVAudioFrameCount(n)
                try file.write(from: buf)
                offset += n
            }
            return true
        } catch {
            return false
        }
    }

    /// Stream-decode a single file in ~10 s blocks so we never hold the
    /// whole native-rate file in memory at once (only the 16 kHz result
    /// grows). Returns an empty array for a zero-frame file, `nil` on a
    /// hard open/convert failure.
    nonisolated private static func decodeFile(url: URL, to out: AVAudioFormat) -> [Float]? {
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

        // One pull = ~10 s of input audio at the file's native rate.
        let inBlock = AVAudioFrameCount(max(inFormat.sampleRate, 16_000) * 10)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inBlock) else { return nil }

        // AVAudioConverter's input block is `@Sendable`; in a nonisolated
        // context it can't capture the non-Sendable file + buffer directly.
        // Hand it ONE `@unchecked Sendable` box instead — AVFoundation calls
        // the block synchronously on this thread for the lifetime of each
        // convert(), so there's no real concurrent access to make unsafe.
        let feed = CAFDecodeFeed(file: file, inBuf: inBuf, blockFrames: inBlock)

        var result: [Float] = []
        result.reserveCapacity(Int(Double(totalFrames) * 16_000 / inFormat.sampleRate) + 1024)

        let ratio = out.sampleRate / inFormat.sampleRate
        // Downsampling (ratio < 1) means one input block always fits in the
        // sized output buffer; the +1024 slack covers resampler look-ahead.
        let outCap = AVAudioFrameCount(Double(inBlock) * ratio + 1024)

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCap) else { break }
            var convError: NSError?
            // Pointer type is inferred here (it's an autoreleasing pointer in
            // the imported AVFoundation signature); we only set its pointee.
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
            // .haveData → keep pulling; .inputRanDry can't occur (the input
            // block only ever returns .haveData or .endOfStream).
        }
        return result
    }
}

// MARK: - Block-wise archive streaming (final pass, 2026-08-10)

/// Streams a `.caf` archive (one or more part files) as ~15-minute
/// 16 kHz mono Float32 blocks instead of one session-sized array.
///
/// Why: `decodeToMono16k` materialises the WHOLE session — ~230 MB/hour
/// per stream, and a 3-hour meeting runs two final passes concurrently.
/// Block-wise reading caps the transient at O(block) and, as a side
/// effect, lets `runFinalTranscribe` release the shared Whisper engine
/// slot between blocks (the other stream's final pass — or a NEW
/// session's live windows — interleave instead of queueing for minutes)
/// and honour cancellation at block boundaries (the archive-length
/// inference itself never was cancellation-aware).
///
/// Boundary rule — never cut mid-word: after the target block length,
/// keep reading up to `cutSearchSeconds` more and cut at the CENTER of
/// the quietest `minQuietSeconds` run in that window (lowest summed
/// energy over 100 ms sub-windows). No threshold to tune: on normal
/// speech this lands in an inter-utterance pause; on pathological
/// continuous sound the quietest run is just the least-bad hard cut.
/// The remainder past the cut is carried as the head of the next block,
/// across `.partN.caf` boundaries too. The proper Silero VAD pre-pass
/// still runs downstream in `WhisperEngine.transcribe` on every block —
/// this scan only picks seams, it never classifies speech.
///
/// Concurrency: `@unchecked Sendable` on the same grounds as
/// `CAFDecodeFeed` below — the reader is driven strictly serially (one
/// `nextBlock()` at a time from one detached task, awaited before the
/// next), it just has to cross the `Task.detached` boundary. `Transcriber`
/// stays `@MainActor`; all decode work happens off-main inside those
/// detached hops.
nonisolated final class ArchiveBlockReader: @unchecked Sendable {
    static let sampleRate = 16_000

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
    /// is earlier than the real one — callers should treat the pass as
    /// incomplete rather than authoritative (and must not delete the
    /// source audio on the strength of it).
    private(set) var skippedParts: [URL] = []

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "ArchiveBlockReader")

    init(urls: [URL],
         blockSeconds: Double = 900,
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
    /// archive (== session-absolute time for a from-0:00 archive).
    /// Blocks are contiguous and non-overlapping: concatenating them
    /// reproduces `decodeToMono16k` exactly.
    func nextBlock() -> (samples: [Float], startSec: Double)? {
        guard let outFormat else { return nil }
        var buf = carry
        carry = []

        let fillLimit = targetSamples + searchSamples
        while !exhausted && buf.count < fillLimit {
            if puller == nil {
                if fileIndex >= urls.count { exhausted = true; break }
                let url = urls[fileIndex]
                fileIndex += 1
                // Missing / unreadable / zero-frame parts are skipped,
                // matching `decodeToMono16k` — but NOT silently. A part
                // that won't open (evicted to iCloud, locked, corrupt)
                // takes its audio out of the transcript AND shortens the
                // timeline: `startSec` counts only what was yielded, so
                // everything after the hole is reported earlier than it
                // happened. Downstream that means moment markers,
                // screenshots and — worst — a diarization pass reading
                // mic and system through two independent readers, where
                // one hole desynchronises every speaker label
                // (audit 2026-09-01).
                guard FileManager.default.fileExists(atPath: url.path),
                      let next = CAFPartPuller(url: url, out: outFormat) else {
                    skippedParts.append(url)
                    Self.log.error("Archive block reader: part \(url.lastPathComponent, privacy: .public) could not be opened — its audio is missing from this pass and everything after it shifts earlier")
                    continue
                }
                puller = next
            }
            if let chunk = puller?.nextChunk() {
                buf.append(contentsOf: chunk)
            } else {
                puller = nil  // part exhausted (or errored mid-file) — advance
            }
        }

        guard !buf.isEmpty else { return nil }
        let startSec = Double(yieldedSamples) / Double(Self.sampleRate)

        // EOF: everything that's left is the last block (≤ target+search,
        // ~16 min) — no seam to pick.
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
    /// by summed energy (Σx²). The search region is bounded by
    /// `fillLimit`, ≤ 60 s ≈ 960k floats — a plain loop is fine.
    private func quietestCut(in buf: [Float]) -> Int {
        let windowSamples = Self.sampleRate / 10  // 100 ms
        let runWindows = max(1, quietRunSamples / windowSamples)
        let searchStart = targetSamples
        // Clamp to the stated 60 s bound: the fill loop appends whole
        // ~10 s chunks and can overshoot `fillLimit` by one chunk.
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
        // Cut at the run's center — deepest into the quiet stretch.
        return searchStart + (bestStart + runWindows / 2) * windowSamples
    }
}

/// One `.caf` part decoded incrementally: each `nextChunk()` performs a
/// single `AVAudioConverter` pull (~10 s of native-rate input) and
/// returns its 16 kHz mono output. Same converter loop as
/// `AudioArchiveDecoder.decodeFile`, minus the accumulation. A convert
/// error mid-file ends the part (partial decode kept), matching
/// `decodeFile`'s behaviour.
nonisolated private final class CAFPartPuller {
    private let converter: AVAudioConverter
    private let feed: CAFDecodeFeed
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
        self.feed = CAFDecodeFeed(file: file, inBuf: inBuf, blockFrames: inBlock)
        let ratio = out.sampleRate / inFormat.sampleRate
        self.outCap = AVAudioFrameCount(Double(inBlock) * ratio + 1024)
    }

    /// `nil` == part fully consumed. May legitimately return an empty
    /// chunk mid-file (resampler priming) — callers just keep pulling.
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

/// Mutable per-file decode state handed to `AVAudioConverter`'s
/// `@Sendable` input block. AVFoundation invokes the block synchronously
/// on the calling thread within a single `convert(...)` — there is no
/// real cross-thread sharing — so `@unchecked Sendable` is sound and lets
/// the (nonisolated) decode closure capture one Sendable reference instead
/// of the non-Sendable `AVAudioFile` + `AVAudioPCMBuffer` directly.
nonisolated private final class CAFDecodeFeed: @unchecked Sendable {
    private let file: AVAudioFile
    private let inBuf: AVAudioPCMBuffer
    private let blockFrames: AVAudioFrameCount
    private var reachedEOF = false

    init(file: AVAudioFile, inBuf: AVAudioPCMBuffer, blockFrames: AVAudioFrameCount) {
        self.file = file
        self.inBuf = inBuf
        self.blockFrames = blockFrames
    }

    /// Read the next block from the file. Returns the filled buffer, or
    /// `nil` once the file is exhausted (caller signals `.endOfStream`).
    func readNext() -> AVAudioPCMBuffer? {
        if reachedEOF { return nil }
        inBuf.frameLength = 0
        do {
            try file.read(into: inBuf, frameCount: blockFrames)
        } catch {
            reachedEOF = true
            return nil
        }
        if inBuf.frameLength == 0 {
            reachedEOF = true
            return nil
        }
        return inBuf
    }
}
