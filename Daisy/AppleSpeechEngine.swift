//
//  AppleSpeechEngine.swift
//  Daisy
//
//  Batch (one-shot) dictation transcription via Apple's SpeechAnalyzer /
//  SpeechTranscriber (macOS 26+). Sibling to `AppleSpeechLiveEngine`
//  (which is streaming/live-preview only): this one takes the FULL
//  recorded mic buffer on dictation-stop and returns the final text to
//  paste — the same role `ParakeetEngine.transcribe(samples:)` plays.
//
//  Why: the recognition model ships inside the OS asset catalog, so it
//  adds ZERO app-bundle weight (unlike bundling a second Whisper), and
//  it runs ~2× faster than Whisper turbo. The trade-off vs Whisper is no
//  diarization / no language auto-detect — fine for dictation (single
//  speaker, one known language), which is why this is a DICTATION engine
//  only; meetings stay on Whisper.
//
//  Requires a concrete locale (no "auto") and macOS 26. Callers gate on
//  `isUsable`; the dictation stop path falls back to Whisper on any miss.
//

import Foundation
import AVFoundation
import Speech
import os

@available(macOS 26, *)
@MainActor
final class AppleSpeechEngine {
    static let shared = AppleSpeechEngine()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppleSpeechEngine")

    private init() {}

    /// SpeechTranscriber exists and the locale is supported. Delegates to
    /// the live engine's checks so the two paths agree.
    static func isUsable(locale: Locale) async -> Bool {
        await AppleSpeechLiveEngine.isUsable(locale: locale)
    }

    /// Ready / still downloading / not a language Apple has at all.
    /// Delegates to the live engine so both paths agree.
    static func availability(locale: Locale) async -> AppleSpeechLiveEngine.Availability {
        await AppleSpeechLiveEngine.availability(locale: locale)
    }

    /// Ensure the locale's on-device model is installed (kicks a
    /// background download if not, returning false so the caller uses
    /// Whisper for this session).
    @discardableResult
    static func ensureModelReady(locale: Locale) async -> Bool {
        await AppleSpeechLiveEngine.ensureModelReady(locale: locale)
    }

    /// Transcribe a 16 kHz mono Float sample buffer (the mic capture the
    /// dictation path already holds) to a single string. Throws on setup
    /// failure; returns "" when nothing was recognized (caller then falls
    /// back to Whisper, same as the Parakeet path).
    func transcribe(samples: [Float], locale: Locale) async throws -> String {
        guard !samples.isEmpty else { return "" }

        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }

        // Collect finalized results concurrently while we feed audio.
        // Inherits MainActor; `pieces` is local to the task.
        let collector = Task { () -> String in
            var pieces: [String] = []
            do {
                for try await result in transcriber.results where result.isFinal {
                    pieces.append(String(result.text.characters))
                }
            } catch {
                self.log.error("Apple batch results ended: \(error.localizedDescription, privacy: .public)")
            }
            return pieces.joined(separator: " ")
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)

        if let source = Self.makeBuffer(samples),
           let converted = Self.convert(source, to: analyzerFormat) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        continuation.finish()

        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum SpeechEngineError: LocalizedError {
        case noAudioFormat
        var errorDescription: String? {
            switch self {
            case .noAudioFormat: return "Apple SpeechAnalyzer returned no compatible audio format."
            }
        }
    }

    // MARK: - Buffer helpers (pure)

    /// Wrap 16 kHz mono Float samples in an AVAudioPCMBuffer.
    nonisolated static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channel[0].update(from: base, count: samples.count)
                }
            }
        }
        return buffer
    }

    /// Convert a buffer to the analyzer's preferred format (mirrors
    /// `AppleSpeechLiveEngine.convert`, single-shot). Returns the input
    /// unchanged when formats already match.
    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var convError: NSError?
        nonisolated(unsafe) let input = buffer
        let status = converter.convert(to: out, error: &convError) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return input
        }
        if status == .haveData || status == .inputRanDry {
            return out.frameLength > 0 ? out : nil
        }
        return nil
    }
}
