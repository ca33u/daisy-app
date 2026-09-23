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
        // Paths come from a file, not the environment. Scheme env vars
        // do not reach the test process here, and hand-editing the
        // .xctestrun to inject them left the runner hanging before it
        // could connect — while the very same host launches fine for
        // every other suite. A file the test reads has neither problem.
        let listURL = URL(fileURLWithPath: "/private/tmp/daisy-diarize-files.txt")
        guard let list = try? String(contentsOf: listURL, encoding: .utf8),
              !list.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("no /private/tmp/daisy-diarize-files.txt — skipping")
            return
        }
        for path in list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard let samples = AudioArchiveDecoder.decodeToMono16k(urls: [url]) else {
                print("\(url.lastPathComponent): could not decode")
                continue
            }
            let started = Date()
            let output = await DiarizationEngine.shared.diarizeFull(samples: samples)
            let speakers = Set(output.spans.map { $0.speakerId }).sorted()
            let seconds = Double(samples.count) / 16_000
            // To a file, not stdout: `xcodebuild` swallows a test's
            // prints, and a measurement nobody can read is not one.
            let line = String(format: "MAC %@: %.0f s audio, %d speaker(s) %@, in %.1f s\n",
                              url.lastPathComponent, seconds, speakers.count,
                              speakers.joined(separator: "/"), Date().timeIntervalSince(started))
                + output.spans.map { String(format: "    %@ %.1f-%.1f\n", $0.speakerId, $0.startSec, $0.endSec) }.joined()
            let out = URL(fileURLWithPath: "/private/tmp/daisy-diarize-result.txt")
            if let existing = try? String(contentsOf: out, encoding: .utf8) {
                try? (existing + line).write(to: out, atomically: true, encoding: .utf8)
            } else {
                try? line.write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }
}
