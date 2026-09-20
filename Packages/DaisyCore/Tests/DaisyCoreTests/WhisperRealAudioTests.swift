//
//  WhisperRealAudioTests.swift
//  DaisyCoreTests
//
//  backlog 6 F-1, the engine on the Mac before the phone: load the
//  626 MB model from a folder and transcribe a real `.caf`, print RTF
//  and text. Skipped unless the environment names the inputs — the Mac
//  app's own model folder and tokenizer base can be used in place:
//
//    DAISY_MODEL_DIR="$HOME/Library/Application Support/Daisy/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB" \
//    DAISY_TOKENIZER_DIR="$HOME/Documents/huggingface" \
//    DAISY_CAF="$HOME/Library/Application Support/Daisy/Sessions/<id>/microphone.caf" \
//    DAISY_OUT=/tmp/whisper-mac.txt swift test --filter WhisperRealAudio
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Whisper real audio")
struct WhisperRealAudioTests {
    @Test func transcribeRealCAF() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelDir = env["DAISY_MODEL_DIR"], !modelDir.isEmpty,
              let cafPath = env["DAISY_CAF"], !cafPath.isEmpty else {
            print("WhisperRealAudioTests: DAISY_MODEL_DIR / DAISY_CAF not set — skipped")
            return
        }
        let tokenizerDir = env["DAISY_TOKENIZER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let engine = WhisperEngine(modelDirectory: URL(fileURLWithPath: modelDir, isDirectory: true), tokenizerDirectory: tokenizerDir)
        let loadStart = Date()
        await engine.load()
        guard engine.isReady else {
            Issue.record("engine not ready: \(engine.state)")
            return
        }
        let loadSec = Date().timeIntervalSince(loadStart)

        let samples = try #require(Resampler.decodeToMono16k(urls: [URL(fileURLWithPath: cafPath)]))
        let result = try await engine.run(samples: samples)
        let text = result.segments.map { "[\(Int($0.startSec))s] \($0.text)" }.joined(separator: "\n")
        let report = """
        load: \(String(format: "%.1f", loadSec)) s
        audio: \(String(format: "%.1f", Double(samples.count) / 16_000)) s
        RTF: \(String(format: "%.3f", result.realTimeFactor))
        language: \(result.language ?? "-")
        segments: \(result.segments.count)

        \(text)
        """
        print(report)
        if let out = env["DAISY_OUT"], !out.isEmpty {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        #expect(!result.segments.isEmpty)
    }
}
