//
//  QueuedFinishTests.swift
//  DaisyTests
//
//  A meeting the queue finishes (a charger wait, a rotation) gets what
//  finalize would have given it (07.10.2026): the summary sees the
//  screen text and the marked moments the same way, and the raw
//  transcript kept next to a polished one has no frontmatter.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct QueuedFinishTests {
    @Test func summaryTranscriptMatchesFinalize() {
        let transcript = "**[0:01 · Me]** Hello\n\n## Shared on screen\n\nSlide 1: Revenue 42"
        let markers = [
            MomentMarker(offsetSec: 65, screenshot: nil, createdAt: Date(timeIntervalSince1970: 1)),
            MomentMarker(offsetSec: 3725, screenshot: nil, createdAt: Date(timeIntervalSince1970: 2)),
        ]
        let text = ImportTranscriptionQueue.summaryTranscript(
            transcript, screenText: "Slide 1: Revenue 42", includeScreenText: true, markers: markers)
        // The section appended to transcript.md is not sent twice: once,
        // fenced as shown-not-spoken.
        #expect(!text.contains("## Shared on screen"))
        #expect(text.components(separatedBy: "Revenue 42").count == 2)
        #expect(text.contains("[Content shared on screen during the meeting"))
        #expect(text.hasSuffix("worth remembering while the meeting was happening: 1:05, 1:02:05]"))
    }

    @Test func screenTextOffKeepsItOutOfTheSummary() {
        let text = ImportTranscriptionQueue.summaryTranscript(
            "Hello\n\n## Shared on screen\n\nSecret slide", screenText: "Secret slide",
            includeScreenText: false, markers: [])
        #expect(text == "Hello")
    }

    @Test func rawTranscriptDropsFrontmatter() {
        let markdown = "---\ntitle: X\n---\n\nBody\n"
        #expect(SessionAudioProcessing.bodyWithoutFrontmatter(markdown) == "\nBody\n")
        #expect(SessionAudioProcessing.bodyWithoutFrontmatter("Body") == "Body")
    }
}
