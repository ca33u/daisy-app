//
//  RepetitionLoopTests.swift
//  DaisyCoreTests
//
//  Инцидент 23.09. A dying stream fed Whisper silence and it looped;
//  with archiving off the loop became the user's meeting notes.
//
//  The filter has to catch that shape and leave real speech alone —
//  people repeat themselves, and deleting what someone actually said
//  would be the same bug facing the other way.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("A loop is a shape, not a phrase")
struct RepetitionLoopTests {

    /// The line from the incident.
    @Test func theIncidentLoopIsCaught() {
        let loop = String(repeating: "я знаю, что ", count: 14) + "я знаю."
        #expect(RepetitionLoop.isLoop(loop))
    }

    @Test func otherShapesOfTheSameFailure() {
        #expect(RepetitionLoop.isLoop(String(repeating: "thank you. ", count: 12)))
        #expect(RepetitionLoop.isLoop(String(repeating: "да ", count: 20)))
        #expect(RepetitionLoop.isLoop(
            String(repeating: "и так далее и так далее ", count: 6)))
    }

    /// Real speech repeats, and it must survive. These are lines from
    /// actual Daisy transcripts.
    @Test func realSpeechIsLeftAlone() {
        for line in [
            "Прикольно, прикольно.",
            "Все, все.",
            "Да, да.",
            "Да надо просто вот мне секунд 30 записей, где говорят два человека.",
            "Она изучила конкурентов и пришла сразу с заданием по конкретному конкуренту, с его запросами, объяснением.",
            "To provide you with the necessary assistance, we will collect your personal information.",
        ] {
            #expect(!RepetitionLoop.isLoop(line), "Dropped real speech: \(line)")
        }
    }

    /// A short line is never a loop, however repetitive: "да, да, да"
    /// is agreement, and at that length there is nothing to lose by
    /// keeping it and everything to lose by not.
    @Test func shortLinesAreNeverLoops() {
        #expect(!RepetitionLoop.isLoop("да да да да"))
        #expect(!RepetitionLoop.isLoop("no no no no no no"))
    }

    /// A long sentence that happens to repeat one word is not a loop —
    /// coverage, not just count, is what decides.
    @Test func oneRepeatedWordInsideRealSpeechIsNotALoop() {
        let line = "Мы обсудили план, и план получился хороший, хотя план на следующий квартал ещё не готов, но общий план понятен всем участникам встречи"
        #expect(!RepetitionLoop.isLoop(line))
    }
}
