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

@Suite("A run of the same short line is silence talking")
struct SilenceRunTests {
    private func seconds(_ mmss: String) -> TimeInterval {
        let p = mmss.split(separator: ":").compactMap { Double($0) }
        return p[0] * 60 + p[1]
    }

    /// The tail of the second user's meeting, 23.09 — line for line.
    /// The call ended at 33:23; what follows is an empty room.
    @Test func theTailOfTheIncidentMeetingIsDropped() {
        let lines: [(String, String)] = [
            ("33:19", "Взаимно. Хорошего дня."),
            ("33:23", "До свидания."),
            ("40:30", "Спасибо."), ("40:31", "Спасибо."), ("40:33", "Спасибо."),
            ("40:35", "Спасибо."), ("40:37", "Спасибо."), ("40:38", "Спасибо."),
            ("43:25", "Спасибо."),
        ]
        let dropped = RepetitionLoop.silenceRunIndices(
            texts: lines.map(\.1), starts: lines.map { seconds($0.0) })
        #expect(dropped == Set(2...7))
    }

    /// The same meeting, mid-call: short thank-yous that may well be
    /// real, in pairs and triples. All kept.
    @Test func pairsAndTriplesFromTheSameMeetingSurvive() {
        let lines: [(String, String)] = [
            ("22:18", "Спасибо."), ("22:19", "Спасибо."), ("22:29", "Спасибо."),
            ("22:43", "Супер. Никита, скажите, может остались какие-то вопросы по функционалу?"),
            ("26:19", "Спасибо."), ("26:21", "Спасибо."),
            ("30:24", "Спасибо."), ("30:25", "Спасибо."),
        ]
        let dropped = RepetitionLoop.silenceRunIndices(
            texts: lines.map(\.1), starts: lines.map { seconds($0.0) })
        #expect(dropped.isEmpty)
    }

    /// Four identical lines spread over minutes are four real remarks.
    @Test func theSameWordMinutesApartIsNotARun() {
        let dropped = RepetitionLoop.silenceRunIndices(
            texts: ["Угу.", "Угу.", "Угу.", "Угу."], starts: [0, 60, 120, 180])
        #expect(dropped.isEmpty)
    }

    /// Long lines never form a run — repetition there is a different
    /// shape, handled by `isLoop`.
    @Test func longLinesAreNotRuns() {
        let line = "Давайте, наверное, чуть подробнее остановимся на том"
        let dropped = RepetitionLoop.silenceRunIndices(
            texts: Array(repeating: line, count: 5), starts: [0, 1, 2, 3, 4])
        #expect(dropped.isEmpty)
    }
}
