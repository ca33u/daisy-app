//
//  TextHighlightTests.swift
//  DaisyCoreTests
//
//  backlog 13 (Egor, 2026-09-23): marking a line the way one marks a
//  book. The rules that matter: toggling twice changes nothing, the
//  markers never eat the words, and a reader that ignores them still
//  reads the sentence.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Highlighting words in a transcript")
struct TextHighlightTests {
    @Test func markingAndUnmarkingLeavesTheTextExactlyAsItWas() {
        let original = "**[0:42 · Me]** We ship on the ninth of November."
        let word = (original as NSString).range(of: "ninth of November")

        let (marked, markedRange) = TextHighlight.toggle(in: original, range: word)
        #expect(marked == "**[0:42 · Me]** We ship on the ==ninth of November==.")
        #expect((marked as NSString).substring(with: markedRange) == "ninth of November")

        // Toggling the same words again gives back the original, to the
        // character — this is what makes it safe to tap twice.
        let (back, backRange) = TextHighlight.toggle(in: marked, range: markedRange)
        #expect(back == original)
        #expect((back as NSString).substring(with: backRange) == "ninth of November")
    }

    @Test func aSelectionWithStraySpacesMarksOnlyTheWords() {
        let text = "Ask about pricing before the demo."
        let sloppy = (text as NSString).range(of: " pricing ")
        let (marked, range) = TextHighlight.toggle(in: text, range: sloppy)
        #expect(marked == "Ask about ==pricing== before the demo.")
        #expect((marked as NSString).substring(with: range) == "pricing")
        // An all-whitespace selection does nothing at all.
        let (unchanged, _) = TextHighlight.toggle(in: text, range: (text as NSString).range(of: " "))
        #expect(unchanged == text)
    }

    @Test func rangesAndStrippingSeeTheSameWords() {
        let text = "==First== plain ==second one== tail"
        let spans = TextHighlight.ranges(in: text).map { String(text[$0]) }
        #expect(spans == ["First", "second one"])
        #expect(TextHighlight.stripped(text) == "First plain second one tail")
        // Empty markers paint nothing.
        #expect(TextHighlight.ranges(in: "a ==== b").isEmpty)
        // An unclosed marker is left alone rather than swallowing the rest.
        #expect(TextHighlight.ranges(in: "==open and never closed").isEmpty)
    }

    @Test func aHighlightStillReadsAsASegmentAndKeepsItsSpeaker() {
        let line = "**[1:05 · Remote A]** The ==price== is fixed."
        let parsed = TranscriptTimeline.parseSegments(line)
        #expect(parsed.count == 1)
        #expect(parsed[0].speaker == "Remote A")
        #expect(parsed[0].startSec == 65)
        // The words are all there for anything that reads text.
        #expect(TextHighlight.stripped(parsed[0].text) == "The price is fixed.")
    }
}

@Suite("Highlights and the rest of the format")
struct HighlightCompatibilityTests {
    /// Everything that reads the words rather than showing them must
    /// see the sentence, not the markers.
    @Test func theWordsSurviveEverythingThatReadsThem() {
        let body = """
        **[0:07 · Me]** We agreed on ==the ninth of November==.

        **[0:42 · Remote A]** And the ==price==?
        """
        // The timeline still sees two segments with their speakers.
        let segments = TranscriptTimeline.parseSegments(body)
        #expect(segments.count == 2)
        #expect(segments[0].speaker == "Me")
        #expect(segments[1].startSec == 42)

        // The transcript still counts as having content (§7.4) — that
        // check gates deleting the only copy of the audio.
        let markdown = "---\ntitle: \"T\"\n---\n\n## Transcript\n\n" + body + "\n"
        #expect(TranscriptDocument.hasTranscriptContent(markdown))

        // Stripping gives a clean sentence for search and summaries.
        #expect(TextHighlight.stripped(segments[0].text) == "We agreed on the ninth of November.")

        // And the speaker-map substitution is unaffected by markers.
        let renamed = SpeakerMapping.apply(["A": "Alex"], to: "**[0:42 · Remote A]** The ==price==.")
        #expect(renamed == "**[0:42 · Alex]** The ==price==.")
    }
}

@Suite("Selecting a highlight offers to remove it")
struct HighlightSelectionStateTests {
    private let text = "We ship on the ==ninth of November== this year."

    private func range(_ substring: String) -> NSRange {
        (text as NSString).range(of: substring)
    }

    /// Egor, 2026-09-23: select the highlighted phrase exactly and the
    /// action must read "remove", not "add another one".
    @Test func selectingTheExactPhraseOffersRemoval() {
        #expect(TextHighlight.state(in: text, range: range("ninth of November")) != .canHighlight)
        // Including the markers — what a drag or a triple tap gives you.
        #expect(TextHighlight.state(in: text, range: range("==ninth of November==")) != .canHighlight)
        // Half of it counts too: a person means "this marked bit".
        #expect(TextHighlight.state(in: text, range: range("November")) != .canHighlight)
        // Plain words elsewhere still offer to highlight.
        #expect(TextHighlight.state(in: text, range: range("this year")) == .canHighlight)
    }

    /// The bug the state machine fixes: selecting the phrase WITH its
    /// markers used to wrap it again — `====like this====`.
    @Test func aSelectionIncludingTheMarkersRemovesRatherThanNests() {
        let (updated, _) = TextHighlight.toggle(in: text, range: range("==ninth of November=="))
        #expect(updated == "We ship on the ninth of November this year.")
        #expect(!updated.contains("===="))
        #expect(TextHighlight.ranges(in: updated).isEmpty)
    }

    @Test func removingFromAPartialSelectionTakesTheWholePhrase() {
        let (updated, kept) = TextHighlight.toggle(in: text, range: range("November"))
        #expect(updated == "We ship on the ninth of November this year.")
        #expect((updated as NSString).substring(with: kept) == "ninth of November")
    }

    @Test func twoHighlightsAreIndependent() {
        let two = "==first== middle ==second=="
        let (afterFirst, _) = TextHighlight.toggle(in: two, range: (two as NSString).range(of: "first"))
        #expect(afterFirst == "first middle ==second==")
        let (afterSecond, _) = TextHighlight.toggle(in: afterFirst, range: (afterFirst as NSString).range(of: "second"))
        #expect(afterSecond == "first middle second")
    }
}
