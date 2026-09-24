//
//  LostSpeechRescueTests.swift
//  DaisyTests
//
//  24.09, Egor's test recording: nine seconds of the other side, clear on
//  the archive, missing from the final transcript. The final pass now
//  re-decodes audible stretches that kept no text; these pin how those
//  stretches are found.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Lost speech: stretches with no text")
struct LostSpeechRescueTests {
    @Test func theNineSecondsFromTheRecordingAreFound() {
        // The span ran 11.3–39 s; what survived was 24–28 and 28–38.
        let kept = [WhisperSegment(start: 24.1, end: 28.6, text: "то как рэперы…"),
                    WhisperSegment(start: 28.6, end: 38.0, text: "представьте себе…")]
        let gaps = WhisperEngine.uncoveredStretches(in: (11.3, 39.0), by: kept, minimum: 3)
        #expect(gaps.count == 1)
        #expect(abs(gaps[0].start - 11.3) < 0.01 && abs(gaps[0].end - 24.1) < 0.01)
    }

    @Test func coveredOrShortStretchesAreLeftAlone() {
        let kept = [WhisperSegment(start: 0, end: 4, text: "a"), WhisperSegment(start: 5.5, end: 10, text: "b")]
        #expect(WhisperEngine.uncoveredStretches(in: (0, 10), by: kept, minimum: 3).isEmpty)
        #expect(WhisperEngine.uncoveredStretches(in: (0, 10), by: [], minimum: 3).count == 1)
    }

    @Test func silenceIsNotRescued() {
        let silence = [Float](repeating: 0, count: 16_000 * 4)
        #expect(WhisperEngine.rmsDB(silence, from: 0, to: 4) < -100)
        let voice = (0..<(16_000 * 4)).map { Float(sin(Double($0) * 0.05)) * 0.1 }
        #expect(WhisperEngine.rmsDB(voice, from: 0, to: 4) > -45)
    }
}
