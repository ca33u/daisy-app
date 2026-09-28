//
//  SummaryFileWriterTests.swift
//  DaisyTests
//
//  The phone's typed `actions` survive the Mac rewriting summary.json —
//  while the steps are the same ones (2026-09-28).
//

import Foundation
import Testing
@testable import Daisy

@Suite("summary.json rewrites keep the phone's actions")
struct SummaryFileWriterTests {
    private let phoneFile = #"""
    {"summary":"Beta","sections":[],"actionItems":["Anna: prepare the release notes"],"clientFollowUp":"",
     "actions":[{"id":"a1","text":"Prepare the release notes","kind":"task","owner":"Anna",
                 "status":{"state":"scheduled","destination":"reminders","at":"2026-09-28T06:00:00Z"}}]}
    """#

    private func write(_ summary: MeetingSummary) throws -> [String: Any] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(phoneFile.utf8).write(to: url)
        try SummaryFileWriter.write(summary, to: url)
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func theSameStepsKeepTheirActionsAndStatuses() throws {
        // The follow-up rewritten in the user's voice: steps untouched.
        let voiced = MeetingSummary(summary: "Beta", sections: [], actionItems: ["Anna: prepare the release notes"],
                                    clientFollowUp: "Hi Anna, …")
        let json = try write(voiced)
        #expect(json["clientFollowUp"] as? String == "Hi Anna, …")
        let actions = try #require(json["actions"] as? [[String: Any]])
        #expect(actions.first?["id"] as? String == "a1")
        #expect((actions.first?["status"] as? [String: Any])?["destination"] as? String == "reminders")
    }

    @Test func newStepsDropTheOldActions() throws {
        let resummarized = MeetingSummary(summary: "Beta", sections: [], actionItems: ["Boris: book the room"],
                                          clientFollowUp: "")
        let json = try write(resummarized)
        #expect(json["actions"] == nil)
        #expect(json["actionItems"] as? [String] == ["Boris: book the room"])
    }

    @Test func aFileWithoutActionsIsWrittenAsBefore() throws {
        let fresh = try JSONEncoder().encode(MeetingSummary(summary: "s", sections: [], actionItems: ["x"], clientFollowUp: ""))
        #expect(SummaryFileWriter.merged(fresh, existing: nil) == fresh)
        let old = try JSONEncoder().encode(MeetingSummary(summary: "old", sections: [], actionItems: ["x"], clientFollowUp: ""))
        #expect(SummaryFileWriter.merged(fresh, existing: old) == fresh)
    }
}
