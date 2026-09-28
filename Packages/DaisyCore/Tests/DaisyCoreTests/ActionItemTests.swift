//
//  ActionItemTests.swift
//  DaisyCoreTests
//
//  Backlog 22 Д-0: typed actions beside the strings, old files still read.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Typed action items")
struct ActionItemTests {
    @Test func anOldFileReadsAsOneOtherItemPerString() throws {
        let json = #"{"summary":"s","sections":[],"actionItems":["Maria: send the contract","Book a room"],"clientFollowUp":""}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.actions.count == 2)
        #expect(summary.actions[0].owner == "Maria")
        #expect(summary.actions[0].text == "send the contract")
        #expect(summary.actions[1].kind == .other)
    }

    @Test func theStringsStayForTheMac() throws {
        let reply = """
        {"summary":"Beta","sections":[],"actionItems":["Anna: prepare the release notes by Friday"],"clientFollowUp":"",
         "actions":[{"text":"Prepare the release notes","kind":"task","owner":"Anna","due":"2026-10-03","with":["Anna"],
                     "confidence":"0.9","payload":{"points":["what changed"],"start":"soon"}}]}
        """
        let summary = try CloudSummaryDTO.decode(from: reply).toMeetingSummary()
        #expect(summary.actionItems == ["Anna: prepare the release notes by Friday"])
        let action = try #require(summary.actions.first)
        #expect(action.kind == .task)
        #expect(action.due == "2026-10-03")
        #expect(action.confidence == 0.9)
        #expect(action.payload?.start == nil)   // "soon" is not a date — dropped, not guessed
        // Written and read back: both keys there; a reader of strings only is unaffected.
        let data = try JSONEncoder().encode(summary)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["actionItems"] as? [String])?.count == 1)
        #expect((object["actions"] as? [[String: Any]])?.count == 1)
    }

    @Test func aStatusIsWrittenIntoTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = MeetingSummary(summary: "s", actionItems: ["Call Boris"], clientFollowUp: "",
                                     actions: [ActionItem(id: "a1", text: "Call Boris", kind: .meeting)])
        try SummaryStore.write(summary, to: dir)
        SummaryStore.setStatus(.init(state: .scheduled, destination: "calendar", identifier: "E1"), forAction: "a1", in: dir)
        let read = try #require(SummaryStore.read(from: dir))
        #expect(read.actions.first?.status?.state == .scheduled)
        #expect(read.actions.first?.status?.identifier == "E1")
    }

    @Test func mineMeansNoOwnerMeOrMyName() {
        #expect(ActionItem(text: "x").isMine(ownerName: "Egor"))
        #expect(ActionItem(text: "x", owner: "me").isMine(ownerName: nil))
        #expect(ActionItem(text: "x", owner: "Egor Sazanov").isMine(ownerName: "Egor"))
        #expect(!ActionItem(text: "x", owner: "Maria").isMine(ownerName: "Egor"))
    }
}

@Suite("Typed actions through the proxy")
struct ActionItemPseudonymTests {
    @Test func namesComeBackInsideTheActions() {
        var session = PseudonymSession(detectNamedEntities: false, knownPeople: ["Anna Petrova"])
        let masked = session.protect("Anna Petrova will send the deck.")
        #expect(!masked.contains("Anna Petrova"))
        let marker = masked.components(separatedBy: " will").first ?? ""
        let summary = MeetingSummary(summary: "s", actionItems: ["\(marker): send the deck"], clientFollowUp: "",
                                     actions: [ActionItem(text: "Send the deck", kind: .email, owner: marker, with: [marker],
                                                          payload: .init(to: [marker]))])
        let restored = session.restore(summary)
        #expect(restored.actions.first?.owner == "Anna Petrova")
        #expect(restored.actions.first?.with == ["Anna Petrova"])
        #expect(restored.actions.first?.payload?.to == ["Anna Petrova"])
        #expect(restored.actions.first?.kind == .email)
    }
}
