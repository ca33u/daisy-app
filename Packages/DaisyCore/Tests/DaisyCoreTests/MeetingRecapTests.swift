//
//  MeetingRecapTests.swift
//  DaisyCoreTests
//
//  Backlog 24 М-1: one recap text for the phone and the Mac.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Meeting recap")
struct MeetingRecapTests {
    @Test func decisionsThenStepsThenOneLineInTheMeetingsLanguage() {
        let actions = [
            ActionItem(text: "Берём тариф Pro", kind: .decision),
            ActionItem(text: "Прислать договор", kind: .email, owner: "Мария", due: "2026-10-03"),
            ActionItem(text: "Не наше", kind: .task, status: .init(state: .dismissed)),
        ]
        let body = MeetingRecap.body(actions: actions, language: .russian)
        #expect(body.hasPrefix("Решили:\n• Берём тариф Pro"))
        #expect(body.contains("• Прислать договор — Мария, до 3 окт"))
        #expect(!body.contains("Не наше"))
        #expect(MeetingRecap.recipients(eventEmails: ["me@x.io", "a@b.c"], ownEmails: ["ME@x.io"], leadEmails: []) == ["a@b.c"])
        #expect(MeetingRecap.stepsText(actions: actions, language: .english).hasPrefix("• Прислать договор — Мария, by"))
    }
}
