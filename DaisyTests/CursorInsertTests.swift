//
//  CursorInsertTests.swift
//  DaisyTests
//
//  Backlog 24 М-10: a step inserted at the cursor gets the phone's status —
//  sent, by paste, into which app — and nothing else in summary.json moves.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Insert at cursor — the step's status")
struct CursorInsertTests {
    private func folder(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        return dir
    }

    private func read(_ dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("summary.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func thePhonesActionGetsTheStatusAndTheRestStays() throws {
        let dir = try folder(#"{"summary":"s","sections":[],"actionItems":["Send the deck","Call Boris"],"clientFollowUp":"f","future":{"x":1},"actions":[{"id":"a1","text":"Send the deck","kind":"email","with":["Maria"],"confidence":1},{"id":"a2","text":"Call Boris","kind":"call","with":[],"confidence":1,"status":{"state":"scheduled","at":"2026-09-29T10:00:00Z","destination":"reminders","identifier":"R1"}}]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        ActionStatusWriter.markPasted(step: 0, into: "Mail", in: dir)
        let root = try read(dir)
        let actions = try #require(root["actions"] as? [[String: Any]])
        let status = try #require(actions[0]["status"] as? [String: Any])
        #expect(status["state"] as? String == "sent")
        #expect(status["destination"] as? String == "paste")
        #expect(status["identifier"] as? String == "Mail")
        #expect(actions[0]["with"] as? [String] == ["Maria"])
        #expect((actions[1]["status"] as? [String: Any])?["identifier"] as? String == "R1")
        #expect(root["future"] != nil)
        #expect(root["clientFollowUp"] as? String == "f")
    }

    @Test func aMacSummaryWithoutActionsGetsThemFromTheStrings() throws {
        let dir = try folder(#"{"summary":"s","sections":[],"actionItems":["Maria: send the contract","Book the room"],"clientFollowUp":""}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        ActionStatusWriter.markPasted(step: 1, into: "Slack", in: dir)
        let actions = try #require(try read(dir)["actions"] as? [[String: Any]])
        #expect(actions.count == 2)
        #expect(actions[0]["owner"] as? String == "Maria")
        #expect(actions[0]["status"] == nil)
        #expect((actions[1]["status"] as? [String: Any])?["identifier"] as? String == "Slack")
    }

    @Test func theRecapMarksOnlyStepsNothingElseClaimed() throws {
        let dir = try folder(#"{"summary":"s","sections":[],"actionItems":["A","B"],"clientFollowUp":"","actions":[{"id":"a1","text":"A","kind":"task","with":[],"confidence":1,"status":{"state":"scheduled","at":"2026-09-29T10:00:00Z","destination":"reminders","identifier":"R1"}},{"id":"a2","text":"B","kind":"task","with":[],"confidence":1}]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        ActionStatusWriter.markRecapSent(steps: 2, in: dir)
        let actions = try #require(try read(dir)["actions"] as? [[String: Any]])
        #expect((actions[0]["status"] as? [String: Any])?["destination"] as? String == "reminders")
        #expect((actions[1]["status"] as? [String: Any])?["destination"] as? String == "participants")
    }

    @Test func aStepThatIsNotThereChangesNothing() throws {
        let json = #"{"summary":"s","sections":[],"actionItems":["One"],"clientFollowUp":""}"#
        let dir = try folder(json)
        defer { try? FileManager.default.removeItem(at: dir) }
        ActionStatusWriter.markPasted(step: 5, into: "Mail", in: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.json"), encoding: .utf8) == json)
    }
}
