//
//  EmbeddedEchoTests.swift
//  DaisyTests
//
//  24.09, Egor's tests on the laptop speakers: the echo of a video landed
//  in the same mic line as his own words, so the whole-line dedup kept
//  it. The lines here are from those two recordings.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Echo inside a line of your own")
struct EmbeddedEchoTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ text: String, _ source: SegmentSource, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), startedAt: origin.addingTimeInterval(start), text: text, isFinal: true,
                          source: source, endSec: end, startSec: start)
    }

    @Test func ownWordsStayAndTheVideoGoes() {
        let mic = line("Ну-ка давай, уровень собеседника, чё мы на YouTube. Второе место - хлеб, чай, сахар. Мы выпускаем ещё 4 песни, и нам уже пишут: \"Давайте в тур\". И мы поехали.", .microphone, 7, 16.5)
        let remote = line("Второе место - хлеб, чай, сахар. Мы выпускаем еще 4 песни и нам уже пишут \"давайте в тур\" и мы поехали в", .systemAudio, 11, 17)
        let out = AcousticEchoDedup.filter([mic, remote])
        #expect(out.count == 2)
        #expect(out[0].text == "Ну-ка давай, уровень собеседника, чё мы на YouTube.")
        #expect(out[0].id == mic.id)
        #expect(out[1] == remote)
    }

    @Test func aLineThatIsOnlyEchoIsDropped() {
        let remote = [
            line("Ему что-то хочется другого.", .systemAudio, 62.8, 64.8),
            line("У меня вот этот мой внутренний рэпер, я же могу написать", .systemAudio, 64.8, 66.8),
            line("просто смешной рэп. Я написал", .systemAudio, 66.8, 68.8),
            line("песню \"Чай сахар\" про то, как", .systemAudio, 68.8, 70.8),
            line("пепперы понтуются тем, что они", .systemAudio, 70.8, 72.5),
        ]
        let echo = line("- \"Тоу, мне что-то хочется другого. А у меня вот этот мой внутренний рэпер, я же могу написать просто смешной рэп. Я написал песню \"Чай сахар\" про то, как рэпер", .microphone, 62.5, 70.5)
        let tail = line("и конкретные ректоры понтуются тем, что они", .microphone, 70.5, 72.8)
        let own = line("Короче пока все еще барахлит", .microphone, 73, 75)
        let out = AcousticEchoDedup.filter([echo] + remote + [tail, own])
        #expect(!out.contains { $0.id == echo.id })
        #expect(!out.contains { $0.id == tail.id })
        #expect(out.contains { $0.id == own.id })
        #expect(out.filter { $0.source == .systemAudio }.count == remote.count)
    }

    @Test func quotingAfterwardsIsKept() {
        let remote = line("мы выпускаем ещё четыре песни и едем в тур", .systemAudio, 10, 13)
        let quote = line("Подожди, ты сказал мы выпускаем ещё четыре песни и едем в тур?", .microphone, 20, 24)
        let out = AcousticEchoDedup.filter([remote, quote])
        #expect(out.contains { $0.id == quote.id && $0.text == quote.text })
    }

    @Test func talkingOverTheOtherSideWithDifferentWordsIsKept() {
        let remote = line("давайте обсудим бюджет на следующий квартал", .systemAudio, 10, 14)
        let mine = line("да, я как раз хотел спросить про сроки запуска", .microphone, 11, 14)
        #expect(AcousticEchoDedup.cutEcho(from: mine.text, remote: ["давайте", "обсудим", "бюджет", "на", "следующий", "квартал"]) == nil)
        #expect(AcousticEchoDedup.filter([remote, mine]).count == 2)
    }
}
