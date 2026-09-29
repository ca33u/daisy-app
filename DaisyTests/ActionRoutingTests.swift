//
//  ActionRoutingTests.swift
//  DaisyTests
//
//  Backlog 24 М-14: one next step, sent where a session can be sent — the
//  lines around it with their time, its owner and date from the typed
//  record, the destination's own template filled with the step.
//

import DaisyCore
import Foundation
import Testing
@testable import Daisy

@Suite("A step to a destination")
@MainActor
struct ActionRoutingTests {
    private let transcript = """
    **[0:05 · Anna]** Morning.

    **[0:12 · Boris]** The export button crashes on the settings screen.

    **[0:20 · Anna]** Since the last build?

    **[0:25 · Boris]** Yes, every time.

    **[0:40 · Anna]** Lunch at one.

    **[0:55 · Boris]** Fine.
    """

    @Test func theLinesAroundTheStepAndItsTime() {
        let (excerpt, time) = ActionRouting.excerpt(for: "Fix the export crash on the settings screen", in: transcript)
        #expect(time == "0:12")
        #expect(excerpt.hasPrefix("[0:05 · Anna] Morning."))
        #expect(excerpt.contains("[0:12 · Boris] The export button crashes on the settings screen."))
        #expect(!excerpt.contains("**"))
        #expect(!excerpt.contains("Fine."))
        #expect(ActionRouting.excerpt(for: "Book flights", in: transcript).0.isEmpty)
    }

    @Test func theTypedRecordGivesOwnerAndDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"summary":"s","actionItems":["Maria: send the deck"],"clientFollowUp":"","actions":[{"id":"a1","text":"Send the deck","kind":"email","owner":"Maria","due":"2026-10-03","with":[],"confidence":1}]}"#
            .write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let action = try #require(ActionRouting.typedAction(0, in: dir))
        #expect(action.owner == "Maria")
        #expect(action.due == "2026-10-03")
        #expect(ActionRouting.typedAction(1, in: dir) == nil)
    }

    @Test func aBodySaysWhoWhenWhereAndWhat() {
        let step = ActionRouting.Step(index: 0, text: "Fix the export crash", owner: "Boris", due: "2026-10-03",
                                      timecode: "0:12", excerpt: "[0:12 · Boris] It crashes", meetingTitle: "Sync",
                                      meetingDate: Date(timeIntervalSince1970: 1_790_000_000))
        let body = step.bodyLines.joined(separator: "\n")
        #expect(body.contains("Boris"))
        #expect(body.contains("Sync"))
        #expect(body.contains("0:12"))
        #expect(body.hasSuffix("[0:12 · Boris] It crashes"))
        let mine = ActionRouting.Step(index: 0, text: "x", owner: "me", due: nil, timecode: nil, excerpt: "",
                                      meetingTitle: "Sync", meetingDate: Date())
        #expect(mine.bodyLines.count == 1)   // only the meeting
    }

    @Test func theDestinationsReplyGivesTheLink() {
        let reply = MCPDispatcher.SendResult(ok: true, reply: #"{"id":"ENG-42","url":"https://linear.app/acme/issue/ENG-42"}"#)
        #expect(reply.link == "https://linear.app/acme/issue/ENG-42")
        #expect(MCPDispatcher.SendResult(ok: true, reply: "created").link == nil)
    }
}
