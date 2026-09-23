//
//  TranscriptTimelineTests.swift
//  DaisyCoreTests
//
//  backlog 13 М-2: a photo belongs where it was taken. The merge is a
//  view over what is already on disk — the rules it must obey are the
//  contract's: §3.3 order, §7.6 "added later".
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Photos inside the transcript (М-2)")
struct TranscriptTimelineTests {
    private let body = """
    **[0:07 · Me]** First line.

    **[0:42 · Me]** Second line.

    **[1:30 · Remote A]** Third line.
    """

    @Test func framesLandBetweenTheLinesTheyWereTakenBetween() {
        let items = TranscriptTimeline.items(
            body: body,
            frames: ["001.jpg": 45, "002.jpg": 8],
            durationSec: 120
        )
        let order: [String] = items.map {
            switch $0 {
            case .segment(let s): "text \(Int(s.startSec))"
            case .photo(let p): "photo \(p.file)"
            }
        }
        #expect(order == ["text 7", "photo 002.jpg", "text 42", "photo 001.jpg", "text 90"])
    }

    @Test func aFrameStampedPastTheEndGoesLastAndIsMarked() {
        let items = TranscriptTimeline.items(
            body: body,
            frames: ["001.jpg": 45, "003.jpg": 900_000],   // a card photographed later
            durationSec: 120
        )
        guard case .photo(let last) = items.last else {
            Issue.record("the last item should be the later photo")
            return
        }
        #expect(last.file == "003.jpg")
        #expect(last.isAddedLater)
        // And the one taken during the meeting is not marked.
        let during = items.compactMap { if case .photo(let p) = $0, p.file == "001.jpg" { return p } else { return nil } }
        #expect(during.first?.isAddedLater == false)
    }

    @Test func aPhotoAtTheSameSecondFollowsTheLineBeingSaid() {
        let items = TranscriptTimeline.items(body: body, frames: ["001.jpg": 42], durationSec: 120)
        let index = items.firstIndex { if case .photo = $0 { return true } else { return false } }
        #expect(index == 2)   // text 7, text 42, photo
    }

    @Test func segmentsParseWithTheContractsSeparatorAndKeepTheirLine() {
        let segments = TranscriptTimeline.parseSegments(body + "\n\nA stray paragraph that is not a segment.")
        #expect(segments.count == 3)
        #expect(segments[0].speaker == "Me")
        #expect(segments[0].text == "First line.")
        #expect(segments[2].startSec == 90)
        #expect(segments[2].speaker == "Remote A")
        #expect(segments[0].rawLine == "**[0:07 · Me]** First line.")
        #expect(TranscriptTimeline.seconds(from: "1:02:03") == 3723)
        #expect(TranscriptTimeline.seconds(from: "nope") == nil)
    }

    @Test func theScreenshotsSectionIsWrittenAboveTheTranscript() {
        let lines = TranscriptDocument.bodyLines(
            title: "T", started: Date(timeIntervalSince1970: 1_700_000_000), duration: 120,
            segments: [TranscriptSegment(startedAt: Date(), text: "Hello", isFinal: true, startSec: 7, endSec: 9)],
            userDisplayName: "Egor",
            screenshots: ["002.jpg": 900_000, "001.jpg": 45]
        )
        let text = lines.joined(separator: "\n")
        let screenshots = try! #require(text.range(of: TranscriptDocument.screenshotsHeading))
        let transcript = try! #require(text.range(of: TranscriptDocument.transcriptHeading))
        #expect(screenshots.lowerBound < transcript.lowerBound)     // §3.3 order
        #expect(text.contains("![0:45](screenshots/001.jpg)"))
        #expect(text.contains("![added later](screenshots/002.jpg)"))
        // Numeric order, not lexical (§7.6).
        let first = text.range(of: "001.jpg")!, second = text.range(of: "002.jpg")!
        #expect(first.lowerBound < second.lowerBound)
        // Nothing appears when there are no frames.
        let bare = TranscriptDocument.bodyLines(title: "T", started: nil, duration: 0, segments: [], userDisplayName: nil)
        #expect(!bare.joined().contains(TranscriptDocument.screenshotsHeading))
    }
}
