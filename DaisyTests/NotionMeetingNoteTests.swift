//
//  NotionMeetingNoteTests.swift
//  DaisyTests
//
//  The request that makes a Notion meeting note (`NotionMeetingNote`):
//  text stays text, the summary and the transcript are in it, and it fits
//  Notion's limits. Nothing is sent.
//

import Foundation
import Testing
@testable import Daisy

struct NotionMeetingNoteTests {
    private func export(summary: MeetingSummary? = nil, chunks: [String] = [], title: String = "Weekly sync",
                        startedAt: Date? = nil) -> MeetingExportData {
        MeetingExportData(title: title, summary: summary, transcriptChunks: chunks,
                          durationSeconds: 125, locale: "en", startedAt: startedAt)
    }

    private func decoded(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func markdown(_ data: MeetingExportData) throws -> String {
        try #require(try decoded(NotionMeetingNote.body(for: data))["markdown"] as? String)
    }

    // MARK: - Request

    @Test func theBodyIsWhatTheEndpointTakes() throws {
        let body = try decoded(NotionMeetingNote.body(for: export(chunks: ["Hello"])))
        #expect(Set(body.keys) == ["title", "markdown", "markdown_version"])
        #expect(body["title"] as? String == "Weekly sync")
        #expect(body["markdown_version"] as? String == "v2")
        let long = try decoded(NotionMeetingNote.body(for: export(title: String(repeating: "a", count: 3000))))
        #expect((long["title"] as? String)?.count == 2000)
    }

    @Test func theSummaryIsInIt() throws {
        let summary = MeetingSummary(
            summary: "The launch moves to Friday, and the team agreed on who writes the note.",
            sections: [SummarySection(title: "Launch", bullets: [
                SummaryBullet(text: "Friday", children: [SummaryBullet(text: "After lunch")]),
            ])],
            actionItems: ["Write the note"], clientFollowUp: "Hi,\n\nwe ship on Friday"
        )
        let text = try markdown(export(summary: summary, chunks: ["Hello"]))
        #expect(text.contains("## Launch\n\n- Friday\n  - After lunch"))
        #expect(text.contains("- [ ] Write the note"))
        #expect(text.contains("Hi,\n\nwe ship on Friday"))
        #expect(text.hasSuffix("Hello"))
    }

    @Test func aTemplatesSectionsTakeThePlaceOfTheOutline() throws {
        var summary = MeetingSummary(
            summary: "A meeting about the plan for the quarter and what comes after that.",
            sections: [SummarySection(title: "Outline", bullets: [])], actionItems: [], clientFollowUp: ""
        )
        summary.templated = TemplatedSummary(
            template: "t", sections: [SummarySection(title: "Decisions", bullets: [SummaryBullet(text: "Ship")])]
        )
        let text = try markdown(export(summary: summary))
        #expect(text.contains("## Decisions\n\n- Ship"))
        #expect(!text.contains("Outline"))
    }

    // MARK: - Text stays text

    @Test func formattingInSpeechIsEscaped() {
        #expect(NotionMeetingNote.escaped("a * b_c <page> [x] #1 $5 `q`") == ##"a \* b\_c \<page\> [x\] \#1 \$5 \`q\`"##)
        #expect(NotionMeetingNote.escaped("- item") == #"\- item"#)
        #expect(NotionMeetingNote.escaped("1. first") == #"1\. first"#)
        #expect(NotionMeetingNote.escaped("12) twelfth") == #"12\) twelfth"#)
        #expect(NotionMeetingNote.escaped("2026 was fine") == "2026 was fine")
        #expect(NotionMeetingNote.escaped(#"a\b"#) == #"a\\b"#)
        #expect(NotionMeetingNote.escaped("Привет, мир") == "Привет, мир")
        #expect(NotionMeetingNote.escaped("") == "")
        #expect(NotionMeetingNote.escaped("[text](https://example.com)") == #"[text\](https://example.com)"#)
    }

    @Test func emojiAreNotFormatting() {
        // A keycap's «*» is one Character with what follows it.
        #expect(NotionMeetingNote.escaped("a*\u{FE0F}\u{20E3}") == "a\\*\u{FE0F}\u{20E3}")
        #expect(NotionMeetingNote.escaped("status :party: ok") == #"status \:party: ok"#)
        #expect(NotionMeetingNote.escaped("at 1:02:45") == #"at 1\:02:45"#)
        #expect(NotionMeetingNote.escaped("note: 10:30") == "note: 10:30")
    }

    /// What the Library and the import queue hold is the whole document.
    @Test func onlyTheTranscriptOfAStoredMeetingIsSent() {
        let stored = """
        # Weekly sync

        > recorded 23 Nov · 12 min

        ## Summary

        ### Meeting

        The launch moves

        ## Screenshots

        ![0:12](/Users/someone/Daisy/screenshots/1.png)

        ## Transcript

        **[0:12 · You]** Hi ![0:13](/Users/someone/2.png)

        ![0:14](/Users/someone/3.png)

        **[0:15 · Remote]** Hello

        ## Shared on screen

        Secret text
        """
        #expect(TranscriptSpeech.exportBody(stored)
                == "**[0:12 · You]** Hi \n\n\n**[0:15 · Remote]** Hello")
        // A recovered recording, a note with headings typed in it.
        #expect(TranscriptSpeech.exportBody("# Title\n\n> recorded 1 Nov\n\n## Your side\n\nHi\n\n# Typed\n\nx")
                == "## Your side\n\nHi\n\n# Typed\n\nx")
        #expect(TranscriptSpeech.exportBody("## Transcript\r\n\r\nHi ![0:1](/Users/x/Daisy (1)/1.png)\r\nthere")
                == "Hi \nthere")
        #expect(TranscriptSpeech.exportBody("# Title\n\n> recorded 1 Nov\n\n[You] Hi") == "[You] Hi")
        #expect(TranscriptSpeech.exportBody("# Title\n\n## Transcript\n") == "")
    }

    @Test func aTitleCannotOpenABlock() throws {
        let summary = MeetingSummary(
            summary: "A meeting about the plan for the quarter and what comes after that.",
            sections: [SummarySection(title: "One\n# Two", bullets: [SummaryBullet(text: "a\n- b")])],
            actionItems: ["x\n\n## y"], clientFollowUp: ""
        )
        let text = try markdown(export(summary: summary))
        #expect(text.contains(##"## One \# Two"##))
        #expect(text.contains("- a - b"))
        #expect(text.contains(##"- [ ] x \#\# y"##))
    }

    @Test func aTranscriptChunkIsOneBlockWithItsLabelsBold() throws {
        let text = try markdown(export(chunks: ["**[0:12 · You]** Hi *there*\n\n**[0:15 · Remote]** Hello"]))
        #expect(text.contains(#"**0:12 · You** Hi \*there\*"# + "\\\n" + "**0:15 · Remote** Hello"))
    }

    /// What is said over a marked moment is cut from the transcript.
    @Test func markedMomentsAreSentWithoutTheirFrames() {
        let stored = """
        # T

        ## Marked moments

        - **[0:12]** Ask about the price — ![0:12](/Users/someone/1.png)
        - **[0:20]**
        - **[0:31]** Send it

        ## Transcript

        **[0:10 · You]** Hi
        """
        #expect(TranscriptSpeech.exportBody(stored)
                == "**[0:10 · You]** Hi\n\n**[0:12]** Ask about the price\n\n**[0:31]** Send it")
    }

    @MainActor @Test func thePageAndClaudeGetTheOutline() {
        let bullets = [SummaryBullet(text: "Friday", children: [SummaryBullet(text: "After lunch")]), SummaryBullet(text: "Room 2")]
        #expect(NotionExporter.outlineParagraphs(bullets) == ["• Friday\n    • After lunch\n• Room 2"])
        #expect(NotionExporter.outlineParagraphs(bullets, limit: 30) == ["• Friday\n    • After lunch", "• Room 2"])
        let prompt = ClaudeExporter.renderPrompt(data: export(summary: MeetingSummary(
            summary: "s", sections: [SummarySection(title: "Launch", bullets: bullets)], actionItems: [], clientFollowUp: "")))
        #expect(prompt.contains("## Launch\n• Friday\n    • After lunch"))
    }

    // MARK: - Limits

    @Test func aPageGoesInHundreds() {
        #expect(NotionExporter.batches(Array(0..<250)).map(\.count) == [100, 100, 50])
        #expect(NotionExporter.batches(Array(0..<100)).map(\.count) == [100])
        #expect(NotionExporter.batches([Int]()).isEmpty)
    }

    @Test func anIncompletePageIsSaidByAutoSendToo() {
        let incomplete = NotionExporter.NotionError.incompletePage
        #expect(NotionExporter.autoSendFailure(incomplete) == incomplete.localizedDescription)
        #expect(NotionExporter.autoSendFailure(NotionExporter.NotionError.httpError(500, "")) != incomplete.localizedDescription)
    }

    @Test func aSendWaitsAsLongAsNotionAsksAndNoLonger() {
        #expect(NotionExporter.retryDelay("7") == 7)
        #expect(NotionExporter.retryDelay(nil) == 1)
        #expect(NotionExporter.retryDelay("soon") == 1)
        #expect(NotionExporter.retryDelay("-5") == 1)
        #expect(NotionExporter.retryDelay("3600") == 30)
    }

    @Test func aTranscriptThatDoesNotFitIsCutAndTheNoteSaysSo() throws {
        let chunks = (0..<400).map { "\($0) " + String(repeating: "слово ", count: 250) }
        let data = try NotionMeetingNote.body(for: export(chunks: chunks), maxBytes: 100_000)
        #expect(data.count <= 100_000)
        // And not by far: the cut is for size, not a guess.
        #expect(data.count > 80_000)
        let text = try #require(try decoded(data)["markdown"] as? String)
        #expect(text.contains("0 слово"))
        #expect(!text.contains("399 слово"))
        #expect(text.hasSuffix("the rest is in Daisy*"))
    }

    @Test func tooManyBlocksAreCut() throws {
        let data = try NotionMeetingNote.body(for: export(chunks: (0..<50).map { "line \($0)" }), maxBlocks: 20)
        let text = try #require(try decoded(data)["markdown"] as? String)
        #expect(text.components(separatedBy: "\n\n").count <= 20)
        #expect(text.hasSuffix("the rest is in Daisy*"))
    }

    @Test func aTranscriptThatFitsIsWhole() throws {
        let text = try markdown(export(chunks: ["one", "two"]))
        #expect(text.hasSuffix("one\n\ntwo"))
    }

    // MARK: - Answer

    @Test func theAddressComesFromTheNotesID() {
        let answer = Data(#"{"object":"meeting_note_page_result","meeting_note":{"id":"3C90c3cc-0d44-4b50-8888-8dd25736052a"}}"#.utf8)
        #expect(NotionMeetingNote.pageURL(fromResponse: answer).absoluteString
                == "https://www.notion.so/3c90c3cc0d444b5088888dd25736052a")
        // The note is there; only its address isn't known.
        for odd in [#"{"meeting_note":{"id":"../x"}}"#, "{}"] {
            #expect(NotionMeetingNote.pageURL(fromResponse: Data(odd.utf8)).absoluteString == "https://www.notion.so/")
        }
    }

    @Test func refusalsAboutTheTokenAreNamed() {
        func failure(_ status: Int, _ body: String = "{}") -> NotionMeetingNote.Failure? {
            NotionMeetingNote.Failure(status: status, body: Data(body.utf8))
        }
        #expect(failure(401) == .tokenRejected)
        #expect(failure(403, #"{"code":"restricted_resource"}"#) == .needsPersonalToken)
        #expect(failure(403, #"{"code":"workspace_credits_exhausted"}"#) == nil)
        #expect(failure(403, "<html>") == nil)
        #expect(failure(429) == nil)
    }

    @Test func onlyAMeetingNoteNeedsNoParent() {
        #expect(AppSettings.notionIsSetUp(token: "t", parentID: "", kind: NotionMeetingNote.kind))
        #expect(!AppSettings.notionIsSetUp(token: " ", parentID: "", kind: NotionMeetingNote.kind))
        #expect(!AppSettings.notionIsSetUp(token: "t", parentID: "", kind: "page"))
        #expect(AppSettings.notionIsSetUp(token: "t", parentID: "p", kind: "database"))
    }
}
