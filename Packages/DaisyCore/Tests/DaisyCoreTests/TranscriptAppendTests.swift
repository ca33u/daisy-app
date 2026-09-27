//
//  TranscriptAppendTests.swift
//  DaisyCoreTests
//
//  A continued recording's lines land at the end of `## Transcript`,
//  the subtitle and Screenshots follow the new length, nothing else moves.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Appending a continued recording")
struct TranscriptAppendTests {
    private let original = """
    ---
    title: "Call"
    duration_sec: 65
    daisy_speaker_map: {}
    ---

    # Call

    > recorded 27 Sep 2026, 23:05 · 1:05

    ## Transcript

    **[0:00 · Remote A]** Hello.

    **[0:40 · Remote B]** Edited by hand.

    """

    private func segment(_ start: Double, _ text: String, _ id: String?) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), startedAt: Date(), text: text, isFinal: true, source: .systemAudio,
                          speakerId: id, startSec: start, endSec: start + 2)
    }

    @Test func newLinesGoAtTheEndAndTheLengthFollows() {
        let out = TranscriptDocument.appending(
            [segment(70, "Back again.", "A"), segment(75, "Yes.", "B")],
            to: original, duration: 80, userDisplayName: nil, screenshots: [:])
        #expect(out.contains("> recorded 27 Sep 2026, 23:05 · 1:20"))
        #expect(out.contains("**[0:40 · Remote B]** Edited by hand.\n\n**[1:10 · Remote A]** Back again.\n\n**[1:15 · Remote B]** Yes.\n"))
        #expect(out.hasPrefix("---\ntitle: \"Call\"\nduration_sec: 65\n"))   // the caller owns the frontmatter
        #expect(TranscriptDocument.hasTranscriptContent(out))
    }

    @Test func aPhotoFromTheContinuationAppearsAboveTheTranscript() {
        let out = TranscriptDocument.appending(
            [segment(70, "Look.", "A")], to: original, duration: 80, userDisplayName: nil,
            screenshots: ["001.jpg": 72])
        let photo = out.range(of: "![1:12](screenshots/001.jpg)")
        let heading = out.range(of: "## Transcript")
        #expect(photo != nil && heading != nil)
        if let photo, let heading { #expect(photo.lowerBound < heading.lowerBound) }
        #expect(out.components(separatedBy: "## Screenshots").count == 2)
    }

    @Test func nothingSaidChangesOnlyTheLength() {
        let out = TranscriptDocument.appending([], to: original, duration: 80, userDisplayName: nil, screenshots: [:])
        #expect(out == original.replacingOccurrences(of: "· 1:05", with: "· 1:20"))
    }
}
