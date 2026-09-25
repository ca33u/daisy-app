//
//  SpeakerAttributionTests.swift
//  DaisyCoreTests
//
//  The Mac's speaker rules, now shared (25.09): segment ↔ voice, one
//  voice split in two folded back, and §3.6 owner / Remote for a room
//  recording. The owner cases are the Mac's PhoneSpeakerAssignmentTests.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Speaker attribution")
struct SpeakerAttributionTests {
    private func unit(_ values: [Float]) -> [Float] {
        let n = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return values.map { $0 / n }
    }

    private func segment(_ start: Double, _ speaker: String?, _ text: String, length: Double = 2) -> TranscriptSegment {
        TranscriptSegment(startedAt: Date(), text: text, source: .microphone, speakerId: speaker,
                          startSec: start, endSec: start + length)
    }

    // MARK: - Owner / Remote (§3.6)

    @Test func ownerByProfileOthersRemote() {
        let owner = unit([1, 0, 0, 0]), guest = unit([0, 1, 0, 0])
        let segments = [segment(0, "A", "hello"), segment(3, "B", "hi there"), segment(6, "A", "so"), segment(9, "C", "third")]
        let result = SpeakerAttribution.assignRoom(segments: segments,
                                                   centroids: ["A": guest, "B": owner, "C": unit([0, 0, 1, 0])],
                                                   owner: owner)
        #expect(result.ownerCluster == "B")
        #expect(result.segments.map { $0.speakerLabel(displayName: "Egor") } == ["Remote A", "Egor", "Remote A", "Remote B"])
        #expect(result.centroids.keys.sorted() == ["A", "B"])
        #expect(result.centroids["A"] == guest)
    }

    @Test func noProfileMeansNobodyIsTheOwner() {
        let segments = [segment(0, "A", "one"), segment(3, "B", "two"), segment(6, nil, "mumble")]
        let result = SpeakerAttribution.assignRoom(segments: segments, centroids: ["A": unit([1, 0]), "B": unit([0, 1])], owner: nil)
        #expect(result.ownerCluster == nil)
        #expect(result.segments.map { $0.speakerLabel(displayName: "Egor") } == ["Remote A", "Remote B", "Remote"])
    }

    @Test func belowThresholdIsNotTheOwner() {
        let result = SpeakerAttribution.assignRoom(segments: [segment(0, "A", "x")],
                                                   centroids: ["A": unit([0.3, 1, 0])], owner: unit([1, 0, 0]))
        #expect(result.ownerCluster == nil)
        #expect(result.segments[0].speakerLabel(displayName: "Egor") == "Remote A")
    }

    // MARK: - Segment ↔ voice

    @Test func aSegmentTakesTheVoiceCoveringMostOfIt() {
        let spans = [SpeakerSpan(speakerId: "A", startSec: 0, endSec: 3), SpeakerSpan(speakerId: "B", startSec: 3, endSec: 10)]
        let out = SpeakerAttribution.merge(segments: [segment(2, nil, "x", length: 4), segment(20, nil, "y")], spans: spans)
        #expect(out[0].speakerId == "B")     // 3 of its 4 seconds are B's
        #expect(out[1].speakerId == nil)     // nobody covers it
    }

    // MARK: - One voice split in two

    @Test func aSingleShortStretchJoinsTheVoiceBesideIt() {
        // The 24 s solo note of 22.08, as the block pass measured it on 25.09.
        let spans = [SpeakerSpan(speakerId: "A", startSec: 0.5, endSec: 18.7),
                     SpeakerSpan(speakerId: "B", startSec: 20.4, endSec: 23.8)]
        let out = SpeakerAttribution.absorbFleetingVoices(spans: spans, centroids: ["A": unit([1, 0]), "B": unit([0, 1])])
        #expect(Set(out.spans.map(\.speakerId)) == ["A"])
        #expect(out.centroids.keys.sorted() == ["A"])
    }

    @Test func aRealSecondSpeakerStays() {
        // The 39 s two-person file: B speaks 15 s in several stretches.
        let spans = [SpeakerSpan(speakerId: "A", startSec: 0, endSec: 4), SpeakerSpan(speakerId: "B", startSec: 5, endSec: 12),
                     SpeakerSpan(speakerId: "B", startSec: 12.5, endSec: 20), SpeakerSpan(speakerId: "A", startSec: 22, endSec: 36)]
        let out = SpeakerAttribution.absorbFleetingVoices(spans: spans, centroids: ["A": unit([1, 0]), "B": unit([0, 1])])
        #expect(out.spans.map(\.speakerId) == ["A", "B", "B", "A"])
    }

    @Test func aShortVoiceHeardTwiceIsAPerson() {
        let spans = [SpeakerSpan(speakerId: "A", startSec: 0, endSec: 30), SpeakerSpan(speakerId: "B", startSec: 31, endSec: 32),
                     SpeakerSpan(speakerId: "A", startSec: 33, endSec: 60), SpeakerSpan(speakerId: "B", startSec: 61, endSec: 62)]
        let out = SpeakerAttribution.absorbFleetingVoices(spans: spans, centroids: [:])
        #expect(Set(out.spans.map(\.speakerId)) == ["A", "B"])
    }

    @Test func aFleetingFirstVoiceGivesWayAndLabelsStartAtA() {
        let spans = [SpeakerSpan(speakerId: "A", startSec: 0, endSec: 2), SpeakerSpan(speakerId: "B", startSec: 2.5, endSec: 40)]
        let out = SpeakerAttribution.absorbFleetingVoices(spans: spans, centroids: ["A": unit([0, 1]), "B": unit([1, 0])])
        #expect(out.spans.map(\.speakerId) == ["A", "A"])
        #expect(out.centroids["A"] == unit([1, 0]))   // the solid voice's centroid, under its new label
    }

    // MARK: - Names across two diarizations

    @Test func namesFollowTheirVoiceToNewLetters() {
        let phone: [String: [Float]] = ["A": unit([1, 0, 0]), "B": unit([0, 1, 0]), "C": unit([0, 0, 1])]
        let mac: [String: [Float]] = ["A": unit([0.05, 1, 0]), "B": unit([0, 0.1, 1]), "C": unit([1, 0.1, 0])]
        let carried = SpeakerAttribution.carryNames(["B": "Egor", "C": "Garmin agent", "A": "Remote B"], from: phone, to: mac)
        #expect(carried == ["A": "Egor", "B": "Garmin agent"])
    }

    @Test func aVoiceNobodyMatchesLosesItsName() {
        let carried = SpeakerAttribution.carryNames(["A": "Maria"], from: ["A": unit([1, 0])], to: ["A": unit([0, 1])])
        #expect(carried.isEmpty)
    }

    @Test func twoNamesNeverLandOnOneVoice() {
        let old: [String: [Float]] = ["A": unit([1, 0.1]), "B": unit([1, 0.2])]
        let carried = SpeakerAttribution.carryNames(["A": "Ann", "B": "Bob"], from: old, to: ["A": unit([1, 0.1])])
        #expect(carried == ["A": "Ann"])
    }
}
