//
//  PhoneSpeakerAssignmentTests.swift
//  DaisyTests
//
//  session-format.md §3.6: on a phone session the microphone track is
//  the room. The owner is found by voice profile; everyone else is
//  `Remote`; with no owner match nobody gets the owner's name.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Phone session speaker assignment (§3.6)")
struct PhoneSpeakerAssignmentTests {
    private func unit(_ values: [Float]) -> [Float] {
        let n = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return values.map { $0 / n }
    }

    private func segment(_ start: Double, _ speaker: String?, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), startedAt: Date(), text: text, isFinal: true,
                          source: .microphone, speakerId: speaker, endSec: start + 2, startSec: start)
    }

    @Test func ownerByProfileOthersRemote() {
        let owner = unit([1, 0, 0, 0])
        let guest = unit([0, 1, 0, 0])
        let segments = [segment(0, "A", "hello"), segment(3, "B", "hi there"), segment(6, "A", "so"), segment(9, "C", "third")]
        let result = PhoneSpeakerAssignment.apply(
            segments: segments,
            centroids: ["A": guest, "B": owner, "C": unit([0, 0, 1, 0])],
            owner: owner
        )
        #expect(result.ownerCluster == "B")
        #expect(result.segments.map { $0.speakerLabel(displayName: "Egor") } == ["Remote A", "Egor", "Remote A", "Remote B"])
        #expect(result.centroids.keys.sorted() == ["A", "B"])
        #expect(result.centroids["A"] == guest)
    }

    @Test func noProfileMeansNobodyIsTheOwner() {
        let segments = [segment(0, "A", "one"), segment(3, "B", "two"), segment(6, nil, "mumble")]
        let result = PhoneSpeakerAssignment.apply(segments: segments, centroids: ["A": unit([1, 0]), "B": unit([0, 1])], owner: nil)
        #expect(result.ownerCluster == nil)
        #expect(result.segments.map { $0.speakerLabel(displayName: "Egor") } == ["Remote A", "Remote B", "Remote"])
    }

    @Test func belowThresholdIsNotTheOwner() {
        let owner = unit([1, 0, 0])
        let far = unit([0.3, 1, 0])   // cosine ≈ 0.29
        let result = PhoneSpeakerAssignment.apply(segments: [segment(0, "A", "x")], centroids: ["A": far], owner: owner)
        #expect(result.ownerCluster == nil)
        #expect(result.segments[0].speakerLabel(displayName: "Egor") == "Remote A")
    }

    @Test func frontmatterMarkerIsRead() {
        let md = "---\ntitle: \"T\"\ndaisy_kind: recording\ndaisy_origin: iphone\n---\n\n# T\n\ndaisy_origin: mac\n"
        #expect(SessionAudioProcessing.frontmatterValue("daisy_origin", in: md) == "iphone")
        #expect(SessionAudioProcessing.frontmatterValue("title", in: md) == "T")
        #expect(SessionAudioProcessing.frontmatterValue("missing", in: md) == nil)
    }
}
