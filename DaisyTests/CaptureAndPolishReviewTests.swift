//
//  CaptureAndPolishReviewTests.swift
//  DaisyTests
//
//  Review of a 30.09 log from Egor's second Mac: ScreenCaptureKit hearing
//  sound after a silent tap blames the tap only when it hears it at once,
//  and a week only after two recordings in a row; a provider that refuses
//  the polish at once is not asked sixteen times.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Silent tap blame and polish refusals")
struct CaptureAndPolishReviewTests {
    private let switched = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func soundAtOnceBlamesTheTapForThisRecordingThenAWeekOnTheSecond() {
        let first = TapBlame.decide(switchedAt: switched, heardAt: switched.addingTimeInterval(3), streak: 0)
        #expect(first == .init(blame: true, setAsideForWeek: false, streak: 1))
        let second = TapBlame.decide(switchedAt: switched, heardAt: switched.addingTimeInterval(8), streak: first.streak)
        #expect(second == .init(blame: true, setAsideForWeek: true, streak: 2))
    }

    @Test func soundThatBeginsLaterIsAQuietRoom() {
        // Egor's 11:00: the tap silent for 120 s, SCK's first sound 45 s after the switch.
        let late = TapBlame.decide(switchedAt: switched, heardAt: switched.addingTimeInterval(45), streak: 1)
        #expect(late == .init(blame: false, setAsideForWeek: false, streak: 1))
    }

    @Test func aProviderThatRefusesAtOnceIsAskedTwiceNotForEveryChunk() async {
        let calls = Counter()
        let segments = (0..<40).map { i in
            TranscriptSegment(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 10),
                              text: String(repeating: "Слово за словом о проекте номер \(i). ", count: 12), isFinal: true)
        }
        #expect(TranscriptPolisher.makeChunks(segments).count > 3)
        let outcome = await TranscriptPolisher.polish(
            segments: segments,
            context: .init(attendees: [], vocabulary: [], meetingApp: nil),
            localeHint: "ru",
            deadlineSeconds: 300,
            summarize: { _, _ in
                await calls.increment()
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No API key"])
            }
        )
        #expect(await calls.value == 2)
        #expect(outcome.chunksApplied == 0)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
