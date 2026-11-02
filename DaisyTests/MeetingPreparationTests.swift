//
//  MeetingPreparationTests.swift
//  DaisyTests
//

import Foundation
import Testing
@testable import Daisy

@Suite("Meeting preparation")
struct MeetingPreparationTests {
    private func meeting(externalID: String? = "provider-event-42") -> DaisyMeeting {
        DaisyMeeting(
            externalID: externalID,
            localID: "local-event-7",
            title: "Acme discovery",
            startDate: Date(timeIntervalSince1970: 1_787_000_000),
            endDate: Date(timeIntervalSince1970: 1_787_003_600),
            location: nil,
            notes: nil,
            meetingURL: URL(string: "https://meet.example/call"),
            meetingPlatform: "meet",
            calendarColorHex: "#FF9500",
            attendees: ["Maria"],
            attendeeEmails: ["maria@acme.test"]
        )
    }

    @MainActor
    @Test("Draft persists by the provider-stable event identity")
    func draftPersistence() throws {
        let suite = ScratchDefaults.suite("test.meeting-preparation")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { ScratchDefaults.remove(suite) }

        let key = "drafts"
        let first = MeetingPreparationStore(defaults: defaults, storageKey: key)
        var draft = first.preparation(
            for: meeting(),
            defaultProjectSlug: "work",
            suggestedTag: "Acme"
        )
        draft.planText = "Confirm budget"
        draft.linkedTaskIDs = ["session-1#0"]
        first.save(draft, now: Date(timeIntervalSince1970: 1_787_000_100))

        let restored = MeetingPreparationStore(defaults: defaults, storageKey: key)
        let value = try #require(restored.preparations["ext:provider-event-42"])
        #expect(value.planText == "Confirm budget")
        #expect(value.projectSlug == "work")
        #expect(value.tag == "Acme")
        #expect(value.linkedTaskIDs == ["session-1#0"])
    }

    @Test("Snapshot freezes plan items and round-trips through the sidecar")
    func snapshotSidecar() throws {
        var preparation = MeetingPreparation(
            meeting: meeting(),
            projectSlug: "sales",
            tag: "Acme",
            now: Date(timeIntervalSince1970: 1_787_000_000)
        )
        preparation.planText = """
        - Introductions
        2. Confirm budget

        Agree next steps
        """
        preparation.planSource = MeetingPlanSource(
            fileName: "sales-script.md",
            typeIdentifier: "net.daringfireball.markdown",
            importedAt: Date(timeIntervalSince1970: 1_787_000_150),
            extractedCharacterCount: 51
        )
        preparation.linkedTaskIDs = ["session-1#0", "session-2#1"]
        let snapshot = MeetingPreparationSnapshot(
            preparation: preparation,
            briefSourceSessionIDs: ["session-1"],
            capturedAt: Date(timeIntervalSince1970: 1_787_000_200)
        )

        #expect(snapshot.planItems.map(\.id) == ["p1", "p2", "p3"])
        #expect(snapshot.planItems.map(\.text) == [
            "Introductions", "Confirm budget", "Agree next steps"
        ])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaisyMeetingPreparationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try snapshot.write(to: directory)
        let loaded = try #require(MeetingPreparationSnapshot.load(from: directory))
        #expect(loaded == snapshot)
        #expect(loaded.planSource?.fileName == "sales-script.md")
    }

    @Test("Legacy preparation JSON without file metadata remains decodable")
    func legacyPreparationJSON() throws {
        let json = """
        {
          "eventID": "ext:legacy-event",
          "eventExternalID": "legacy-event",
          "eventLocalID": "local-event",
          "eventTitle": "Legacy meeting",
          "eventStart": 1787000000,
          "projectSlug": "work",
          "tag": "Client",
          "planText": "Discuss renewal",
          "linkedTaskIDs": [],
          "createdAt": 1787000000,
          "updatedAt": 1787000000
        }
        """

        let decoded = try JSONDecoder().decode(
            MeetingPreparation.self,
            from: try #require(json.data(using: .utf8))
        )
        #expect(decoded.planText == "Discuss renewal")
        #expect(decoded.planSource == nil)
    }

    @Test("Legacy sessions without a preparation sidecar remain valid")
    func missingSidecar() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        #expect(MeetingPreparationSnapshot.load(from: directory) == nil)
    }
}
