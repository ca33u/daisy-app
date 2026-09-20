//
//  MeetingBindingTests.swift
//  DaisyCoreTests
//
//  backlog 5 E-4: a recording started from a meeting writes the Mac's
//  `daisy_event_*` keys, in the Mac's position (after `daisy_tag`,
//  before `daisy_speaker_map`), and the Mac parser reads them back.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Meeting binding in frontmatter")
struct MeetingBindingTests {
    @Test func eventKeysRoundTripInContractOrder() {
        let binding = MeetingBinding(
            externalID: "ABC-123", localID: "local-1", title: "Q3 review — numbers",
            startDate: Date(timeIntervalSince1970: 1_800_000_000), platform: "zoom",
            attendees: ["Alex", "Maria"], attendeeEmails: ["alex@acme.com", "maria@acme.com"]
        )
        var fm = SessionFrontmatter.phoneRecording(title: "Q3 review", started: Date(timeIntervalSince1970: 1_800_000_000), duration: 120, micBytes: 10)
        fm.tag = "acme"
        fm.event = binding
        let text = fm.render() + "\n\nbody\n"
        let parsed = SessionDocument.parseFrontmatter(in: text)

        let order = parsed.keyOrder
        #expect(order.firstIndex(of: "daisy_tag")! < order.firstIndex(of: "daisy_event_external_id")!)
        #expect(order.firstIndex(of: "daisy_event_emails")! < order.firstIndex(of: "daisy_speaker_map")!)
        #expect(parsed["daisy_event_platform"] == "zoom")
        #expect(parsed.attendees == ["Alex", "Maria"])
        #expect(parsed.attendeeEmails == ["alex@acme.com", "maria@acme.com"])

        let back = SessionFrontmatter.parse(text)
        #expect(back?.event == binding)
    }

    @Test func meetingLinkDetectionFollowsTheMacsOrder() {
        let zoom = MeetingURLDetector.detect(in: [nil, "https://us02web.zoom.us/j/123456?pwd=x", "https://meet.google.com/abc-defg-hij"])
        #expect(zoom?.platform == "zoom")
        let meet = MeetingURLDetector.detect(in: ["Room 4", nil, "Join: https://meet.google.com/abc-defg-hij"])
        #expect(meet?.platform == "meet")
        #expect(MeetingURLDetector.detect(in: ["Lunch", nil, nil]) == nil)
    }
}
