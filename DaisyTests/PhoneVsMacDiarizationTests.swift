//
//  PhoneVsMacDiarizationTests.swift
//  DaisyTests
//
//  Бэклог 18 Д-3: the same audio, the same pinned FluidAudio, the same
//  configuration — the Mac and the phone should find the same number of
//  voices. A disagreement is a bug in the port, not "how phones are".
//
//  Env-gated, like `WhisperRealAudioTests`: it needs real recordings
//  and a model download, so it never runs as part of an ordinary suite.
//
//      DAISY_DIARIZE_FILES="/path/a.m4a:/path/b.m4a" \
//      xcodebuild test -only-testing:DaisyTests/PhoneVsMacDiarizationTests
//

import AVFoundation
import Foundation
import Testing
@testable import Daisy

@Suite("Mac diarization on the phone's files", .serialized)
struct PhoneVsMacDiarizationTests {
    @MainActor
    @Test func countSpeakersInEachFile() async throws {
        guard let list = ProcessInfo.processInfo.environment["DAISY_DIARIZE_FILES"], !list.isEmpty else {
            print("DAISY_DIARIZE_FILES not set — skipping")
            return
        }
        for path in list.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path)
            guard let samples = AudioArchiveDecoder.decodeToMono16k(urls: [url]) else {
                print("\(url.lastPathComponent): could not decode")
                continue
            }
            let started = Date()
            let output = await DiarizationEngine.shared.diarizeFull(samples: samples)
            let speakers = Set(output.spans.map { $0.speakerId }).sorted()
            let seconds = Double(samples.count) / 16_000
            print(String(format: "MAC %@: %.0f s audio, %d speaker(s) %@, in %.1f s",
                         url.lastPathComponent, seconds, speakers.count,
                         speakers.joined(separator: "/"), Date().timeIntervalSince(started)))
        }
    }
}
