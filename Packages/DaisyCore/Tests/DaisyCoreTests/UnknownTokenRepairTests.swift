//
//  UnknownTokenRepairTests.swift
//  DaisyCoreTests
//
//  Egor, 30.09: «Наш<unk>л баг…» — the dictation models have no «ё».
//

import Testing
@testable import DaisyCore

@Suite("Unknown token → ё")
struct UnknownTokenRepairTests {
    @Test func egorsSentence() {
        let raw = "Наш<unk>л баг с Android через поиск, добавил контакты себе и начал решил ему позвонить до того, как человек на iPhone принял запрос и звонок прош<unk>л."
        #expect(UnknownTokenRepair.repair(raw)
                == "Нашёл баг с Android через поиск, добавил контакты себе и начал решил ему позвонить до того, как человек на iPhone принял запрос и звонок прошёл.")
    }

    @Test func endsStartsAndCapitals() {
        #expect(UnknownTokenRepair.repair("ещ<unk> раз, вс<unk>") == "ещё раз, всё")
        #expect(UnknownTokenRepair.repair("<unk>лка стоит. <unk>ж убежал") == "Ёлка стоит. Ёж убежал")
        #expect(UnknownTokenRepair.repair("купили <unk>лку") == "купили ёлку")
        #expect(UnknownTokenRepair.repair("ВС<unk> ГОТОВО") == "ВСЁ ГОТОВО")
    }

    @Test func noiseOutsideRussianGoes() {
        #expect(UnknownTokenRepair.repair("hello <unk> world") == "hello world")
        #expect(UnknownTokenRepair.repair("done <unk>.") == "done.")
        #expect(UnknownTokenRepair.repair("plain text") == "plain text")
    }
}
