//
//  ParakeetRealAudioTests.swift
//  DaisyCoreTests
//
//  Engine end-to-end on real audio, gated by the environment so the
//  suite stays hermetic by default:
//
//    DAISY_MODEL_DIR=… DAISY_CAF=… DAISY_OUT=… swift test --filter ParakeetRealAudio
//
//  Same check `DaisyLiteTests/ParakeetSimulatorCheck` runs on the
//  simulator; here it runs on the Mac (Core ML on the host).
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Parakeet real audio")
struct ParakeetRealAudioTests {
    @Test func transcribeRealCAF() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelDir = env["DAISY_MODEL_DIR"], !modelDir.isEmpty,
              let cafPath = env["DAISY_CAF"], !cafPath.isEmpty else { return }
        let modelURL = URL(fileURLWithPath: modelDir, isDirectory: true)
        #expect(ModelStore.verify(at: modelURL))

        var report: [String] = []
        let t0 = Date()
        let samples = try #require(Resampler.decodeToMono16k(urls: [URL(fileURLWithPath: cafPath)]))
        let audioSec = Double(samples.count) / 16_000
        report.append("audio: \(String(format: "%.1f", audioSec)) s, decode+resample: \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")

        let engine = ParakeetEngine(modelDirectory: modelURL)
        let t1 = Date()
        await engine.load()
        report.append("load: \(String(format: "%.2f", Date().timeIntervalSince(t1))) s, state: \(engine.state)")
        #expect(engine.isReady)

        let t2 = Date()
        let segments = try await engine.transcribe(samples: samples)
        let asrSec = Date().timeIntervalSince(t2)
        report.append("transcribe: \(String(format: "%.2f", asrSec)) s → \(segments.count) segments, RTF \(String(format: "%.3f", asrSec / max(audioSec, 0.001)))")
        report.append("")
        for s in segments {
            report.append("[\(TranscriptDocument.formatDuration(s.startSec))–\(TranscriptDocument.formatDuration(s.endSec))] \(s.text)")
        }
        let text = report.joined(separator: "\n")
        print(text)
        if let out = env["DAISY_OUT"], !out.isEmpty {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: out))
        }
        #expect(!segments.isEmpty)
    }
}
