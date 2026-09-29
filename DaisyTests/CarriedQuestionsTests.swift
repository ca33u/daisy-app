//
//  CarriedQuestionsTests.swift
//  DaisyTests
//
//  Backlog 24 М-13: a question the phone carried to the next meeting
//  shows in that meeting's prep on the Mac — found by the provider's
//  event id both devices share.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Questions carried to the next meeting")
struct CarriedQuestionsTests {
    @Test func aCarriedQuestionIsFoundByTheSharedEventID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"summary":"s","actionItems":["Who owns the budget?","Other","Send"],"clientFollowUp":"","actions":[{"id":"q1","text":"Who owns the budget?","kind":"question","with":[],"confidence":1,"status":{"state":"scheduled","at":"2026-09-29T10:00:00Z","destination":"nextMeeting","identifier":"EXT-1"}},{"id":"q2","text":"Other","kind":"question","with":[],"confidence":1,"status":{"state":"scheduled","at":"2026-09-29T10:00:00Z","destination":"nextMeeting","identifier":"EXT-2"}},{"id":"a1","text":"Send","kind":"task","with":[],"confidence":1}]}"#
            .write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let now = Date()
        let sessions = [(id: "S1", title: "Sync", date: now.addingTimeInterval(-86_400), directory: dir)]
        let found = CarriedQuestions.find(eventIDs: ["EXT-1", "local-9"], in: sessions, now: now)
        #expect(found.map(\.text) == ["Who owns the budget?"])
        #expect(found.first?.sessionID == "S1")
        let old = [(id: "S0", title: "Old", date: now.addingTimeInterval(-90 * 86_400), directory: dir)]
        #expect(CarriedQuestions.find(eventIDs: ["EXT-1"], in: old, now: now).isEmpty)
    }
}
