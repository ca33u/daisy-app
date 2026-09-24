//
//  LiveTranscriptGuardTests.swift
//  DaisyTests
//
//  Review 24.09: a recording finished from the queue replaces its live
//  transcript with the final pass — and a final pass that heard nothing
//  would have written «No speech detected.» over the meeting. The live
//  text stays whenever the final pass has less than it.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Finishing a live transcript: the live text is not lost")
struct LiveTranscriptGuardTests {
    private let live = """
    ---
    title: "Meeting 2026-09-24 14:31"
    daisy_kind: meeting
    ---

    # Meeting 2026-09-24 14:31

    ## Transcript

    **[00:00 · Egor]** А вот после того, как я

    **[00:05 · Egor]** После того, как я завершил записи, у меня появились наушники.

    **[00:27 · Remote]** Они такие: "Нет, мы такие: "Давайте заново!" И мы заново поем 4 песни.

    _Recording interrupted._
    """

    @Test func wordsAreCountedWithoutStampsAndNotes() {
        // 6 + 10 + 13
        #expect(SessionAudioProcessing.spokenWordCount(inTranscriptMarkdown: live) == 29)
    }

    @Test func anEmptyFinalPassKeepsTheLiveText() {
        let reason = SessionAudioProcessing.reasonToKeepLiveTranscript(liveWords: 29, finalWords: 0)
        #expect(reason != nil)
    }

    @Test func aFinalPassWithLessThanHalfKeepsTheLiveText() {
        #expect(SessionAudioProcessing.reasonToKeepLiveTranscript(liveWords: 400, finalWords: 150) != nil)
    }

    @Test func aFinalPassThatTrimsEchoAndLoopsReplacesIt() {
        #expect(SessionAudioProcessing.reasonToKeepLiveTranscript(liveWords: 400, finalWords: 260) == nil)
        #expect(SessionAudioProcessing.reasonToKeepLiveTranscript(liveWords: 400, finalWords: 520) == nil)
    }

    @Test func aShortLiveTextIsNotJudgedByRatio() {
        // Eight live words, three final: too few for a ratio to mean much.
        #expect(SessionAudioProcessing.reasonToKeepLiveTranscript(liveWords: 8, finalWords: 3) == nil)
        #expect(SessionAudioProcessing.reasonToKeepLiveTranscript(liveWords: 0, finalWords: 0) == nil)
    }
}
