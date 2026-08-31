//
//  AppleSpeechLiveEngine.swift
//  Daisy
//
//  Live (streaming) transcription backed by Apple's SpeechAnalyzer /
//  SpeechTranscriber (macOS 26+). Used as the "Lite" live engine:
//   • the recognition model lives in the system asset catalog →
//     ZERO app memory (unlike a second resident WhisperKit instance);
//   • volatile/finalized results map directly onto Transcriber's
//     pending/committed model (`Result.isFinal`);
//   • ~2× faster than Whisper turbo on the same audio.
//
//  ONLY the live preview runs through this. The authoritative pass on
//  Stop is always WhisperKit turbo — it carries diarization + language
//  detection, which SpeechTranscriber does not. On macOS < 26, an
//  unsupported/auto locale, a not-yet-installed model, or any error,
//  `Transcriber` transparently falls back to the Whisper-Lite decode
//  profile (the rolling-window timer path).
//

import Foundation
import AVFoundation
import CoreMedia
import Speech
import os

/// One live result chunk, normalized to the session-relative shape the
/// `Transcriber` consumes. Times are relative to the engine's first fed
/// buffer; `Transcriber` adds its own start offset.
struct AppleLiveResult: Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
    let isFinal: Bool
}

@available(macOS 26, *)
@MainActor
final class AppleSpeechLiveEngine {
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppleSpeechLiveEngine")

    private let locale: Locale
    private let onResult: @MainActor (AppleLiveResult) -> Void

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    init(locale: Locale, onResult: @escaping @MainActor (AppleLiveResult) -> Void) {
        self.locale = locale
        self.onResult = onResult
    }

    /// SpeechTranscriber exists on this machine AND the locale is
    /// supported. Call before constructing/starting an instance.
    static func isUsable(locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    /// Why Apple can or can't run this language — the cases the caller
    /// has to tell apart, because they mean different things to the
    /// person: `.unsupported` is permanent (Apple has no model for this
    /// language at all), `.notInstalled` fixes itself once the download
    /// lands, `.frameworkUnavailable` isn't about the language at all,
    /// and `.ready` is the happy path.
    ///
    /// They used to be collapsed into one Bool, which turned a field
    /// report into a day of guessing: the log said "unsupported or model
    /// not installed" and the answer for Russian looked like "Apple
    /// doesn't do Russian" when the real story was an asset that never
    /// arrived (Егор, 2026-08-31 — "русский отлично работает на телефоне
    /// и на компе", and he's right: the system's own dictation does).
    enum Availability: Sendable {
        case ready
        case notInstalled
        case unsupported
        /// SpeechTranscriber itself isn't available on this machine —
        /// nothing to do with the chosen language. Its own case so the
        /// warning doesn't blame a language that's perfectly fine (the
        /// mistake this enum exists to stop making).
        case frameworkUnavailable
    }

    static func availability(locale: Locale) async -> Availability {
        guard SpeechTranscriber.isAvailable else { return .frameworkUnavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }
        let target = supported.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains(where: { $0.identifier(.bcp47) == target })
            ? .ready
            : .notInstalled
    }

    /// Whether the locale's on-device model is installed *right now*. If
    /// it isn't, kicks a best-effort background download (so a later
    /// session can use Apple) and returns false — the caller falls back
    /// to Whisper-Lite for this session rather than blocking on a large
    /// model pull.
    static func ensureModelReady(locale: Locale) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return false
        }
        let target = supported.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) {
            return true
        }
        // One download attempt in flight per locale. Every dictation used
        // to kick a fresh one, so a language whose asset keeps failing got
        // a new doomed request on every hotkey press.
        guard !installsInFlight.contains(target) else {
            Logger(subsystem: "app.essazanov.Daisy", category: "AppleSpeechLiveEngine")
                .info("Apple speech: download for \(target, privacy: .public) already in flight — skipping")
            return false
        }
        installsInFlight.insert(target)
        Task.detached {
            let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppleSpeechLiveEngine")
            do {
                let probe = SpeechTranscriber(
                    locale: supported,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange]
                )
                try await AssetInventory.reserve(locale: supported)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    log.info("Apple speech: downloading model for \(target, privacy: .public)…")
                    try await request.downloadAndInstall()
                    log.info("Apple speech: model for \(target, privacy: .public) installed")
                } else {
                    // No request to make, yet the locale isn't installed:
                    // the asset catalog thinks it's covered when it isn't.
                    log.warning("Apple speech: no installation request for \(target, privacy: .public) — model stays missing")
                }
            } catch {
                // Whisper-Lite covers this session regardless, but the
                // failure must NOT be silent: this is exactly where a
                // supported language looks unsupported forever.
                log.error("Apple speech: model download for \(target, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { _ = installsInFlight.remove(target) }
        }
        return false
    }

    /// bcp47 identifiers whose asset download is running right now.
    private static var installsInFlight: Set<String> = []

    func start() async throws {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Drain results → normalized callback. Inherits MainActor from
        // the enclosing isolation, so `onResult` is called on the main
        // actor as Transcriber requires.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let normalized = AppleLiveResult(
                        text: String(result.text.characters),
                        startSec: result.range.start.seconds,
                        endSec: result.range.end.seconds,
                        isFinal: result.isFinal
                    )
                    self.onResult(normalized)
                }
            } catch {
                self.log.error("Apple results stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)
    }

    /// Convert a captured buffer to the analyzer's format and feed it.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation, let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        converterInput = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = analyzerFormat else { return buffer }
        if buffer.format == targetFormat { return buffer }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var convError: NSError?
        // The input block runs synchronously inside `convert`, so handing it
        // the (non-Sendable) buffer is safe — opt out of the @Sendable capture
        // check explicitly rather than broadly @preconcurrency-ing AVFAudio.
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
