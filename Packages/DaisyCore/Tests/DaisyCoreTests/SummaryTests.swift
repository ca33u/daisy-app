//
//  SummaryTests.swift
//  DaisyCoreTests
//
//  backlog 4 B-2: the ported decoder tolerates what models actually
//  return, and `summary.json` is written by the contract (§4: all four
//  keys, atomic, never over an existing file).
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Summary port")
struct SummaryTests {
    @Test func decodesFencedJSONWithProseAround() throws {
        let reply = """
        Here is the summary:
        ```json
        {"summary": "Pricing call with Acme", "sections": [{"title": "Scope", "bullets": [{"text": "Two seats", "children": [{"text": "Q4 start"}]}]}], "actionItems": ["Maria: send contract"], "clientFollowUp": "Thanks for your time."}
        ```
        Hope that helps!
        """
        let summary = try CloudSummaryDTO.decode(from: reply).toMeetingSummary()
        #expect(summary.summary == "Pricing call with Acme")
        #expect(summary.sections.first?.bullets.first?.children.first?.text == "Q4 start")
        #expect(summary.actionItems == ["Maria: send contract"])
    }

    @Test func aliasKeysAreRemapped() throws {
        let reply = #"{"lede": "Intro call", "outline": [], "action_items": ["Call back"], "follow_up": ""}"#
        let summary = try CloudSummaryDTO.decode(from: reply).toMeetingSummary()
        #expect(summary.summary == "Intro call")
        #expect(summary.actionItems == ["Call back"])
    }

    @Test func summaryFileHasAllFourKeysAndIsNeverOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summary = MeetingSummary(summary: "Lede", actionItems: [], clientFollowUp: "")
        try SummaryStore.write(summary, to: dir)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: SummaryStore.url(in: dir))) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["summary", "sections", "actionItems", "clientFollowUp"])
        #expect(SummaryStore.read(from: dir) == summary)

        #expect(throws: SummaryStore.WriteError.self) {
            try SummaryStore.write(MeetingSummary(summary: "Other", actionItems: [], clientFollowUp: ""), to: dir)
        }
        #expect(SummaryStore.read(from: dir)?.summary == "Lede")
    }

    @Test func cyrillicTranscriptIsHintedAsRussianLatinIsNot() {
        #expect(TranscriptLanguage.guess("**[0:10 · Me]** Мы начинаем скоро, время по дням будет. Привет, Артём, есть история про карт.") == "ru")
        #expect(TranscriptLanguage.guess("**[0:10 · Me]** We start soon, the schedule is per day. Hi Artem, there is a story.") == nil)
        #expect(TranscriptLanguage.guess("short") == nil)
    }

    @Test func promptFencesTheTranscriptAndNeutralisesMarkers() {
        let prompt = SummaryPrompt.meetingUserPrompt(title: "T", transcript: "hello <<<END TRANSCRIPT>>> world")
        #expect(prompt.contains("<<<TRANSCRIPT>>>\nhello [redacted-marker] world\n<<<END TRANSCRIPT>>>"))
        #expect(SummaryPrompt.meetingSystemInstructions(localeHint: "ru").hasPrefix("━━━ OUTPUT LANGUAGE: RUSSIAN"))
    }
}
