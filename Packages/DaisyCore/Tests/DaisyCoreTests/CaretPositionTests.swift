//
//  CaretPositionTests.swift
//  DaisyCoreTests
//
//  backlog 13 М-1: what "insert here" means in a transcript.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Inserting at the caret (М-1)")
struct CaretPositionTests {
    private let body = """
    **[0:07 · Me]** First line.

    **[0:42 · Me]** Second line.

    **[1:30 · Remote A]** Third line.
    """

    @Test func theCaretTakesTheSecondOfTheLineItStandsIn() {
        let inFirst = (body as NSString).range(of: "First").location + 2
        #expect(CaretPosition.second(inBody: body, at: inFirst) == 7)
        let inSecond = (body as NSString).range(of: "Second").location + 3
        #expect(CaretPosition.second(inBody: body, at: inSecond) == 42)
        let inThird = (body as NSString).range(of: "Third").location
        #expect(CaretPosition.second(inBody: body, at: inThird) == 90)
        // Before anything was said there is no second to claim.
        #expect(CaretPosition.second(inBody: "A note\n\n" + body, at: 2) == nil)
    }

    @Test func insertionLandsAfterTheLineAndLeavesTheRestAlone() {
        let offset = (body as NSString).range(of: "Second").location + 3
        let line = CaretPosition.segmentLine(second: 42, speaker: "Me", text: "Spoken note.")
        let (updated, caret) = CaretPosition.insert(line, into: body, at: offset)
        let lines = updated.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines == [
            "**[0:07 · Me]** First line.",
            "**[0:42 · Me]** Second line.",
            "**[0:42 · Me]** Spoken note.",
            "**[1:30 · Remote A]** Third line.",
        ])
        // Everything that was there is still there, in order.
        #expect(updated.contains("**[0:07 · Me]** First line."))
        #expect(updated.contains("**[1:30 · Remote A]** Third line."))
        // The caret ends after what was inserted.
        #expect((updated as NSString).substring(to: caret).hasSuffix("Spoken note."))
        // And the new line parses as a segment, so the timeline sees it.
        let parsed = TranscriptTimeline.parseSegments(updated)
        #expect(parsed.count == 4)
        #expect(parsed[2].text == "Spoken note.")
    }

    @Test func insertingAtTheVeryEndDoesNotLoseTheLastLine() {
        let (updated, _) = CaretPosition.insert("**[1:30 · Me]** Tail.", into: body, at: (body as NSString).length)
        #expect(updated.hasSuffix("**[1:30 · Me]** Tail.\n") || updated.hasSuffix("**[1:30 · Me]** Tail."))
        #expect(updated.contains("**[1:30 · Remote A]** Third line."))
        #expect(TranscriptTimeline.parseSegments(updated).count == 4)
    }
}
