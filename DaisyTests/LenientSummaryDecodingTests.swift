//
//  LenientSummaryDecodingTests.swift
//  DaisyTests
//
//  A user lost a 48-minute summary three times running to «JSON schema
//  mismatch (… missing)»: valid JSON with one section or bullet short of
//  a field threw the whole reply away (log report 03.11.2026). These pin
//  that a broken element is mended or left out and the rest is kept.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Lenient summary decoding")
struct LenientSummaryDecodingTests {
    private func decode(_ json: String) throws -> MeetingSummary {
        try CloudSummaryDTO.decode(from: json).toMeetingSummary()
    }

    @Test("A null section title and a null bullet text no longer cost the summary")
    func nullsInsideElements() throws {
        let summary = try decode("""
        {"title": "Запуск", "summary": "Обсудили запуск.",
         "sections": [
           {"title": "План", "bullets": [{"text": "Релиз в мае", "children": [{"text": null}]}, {"text": null, "children": []}]},
           {"title": null, "bullets": [{"text": "Бюджет согласован", "children": []}]}
         ],
         "actionItems": ["Анна: прислать бюджет", null],
         "clientFollowUp": ""}
        """)
        #expect(summary.title == "Запуск")
        #expect(summary.summary == "Обсудили запуск.")
        #expect(summary.sections.map(\.title) == ["План"])
        #expect(summary.sections.first?.bullets.map(\.text) == ["Релиз в мае", "Бюджет согласован"])
        #expect(summary.sections.first?.bullets.first?.children.isEmpty == true)
        #expect(summary.actionItems == ["Анна: прислать бюджет"])
    }

    @Test("Missing keys read like nulls")
    func missingKeys() throws {
        let summary = try decode("""
        {"summary": "Lede", "sections": [{"title": "Scope", "bullets": [{"children": []}, {"text": "Two seats"}]}, {}], "actionItems": []}
        """)
        #expect(summary.sections.count == 1)
        #expect(summary.sections.first?.bullets.map(\.text) == ["Two seats"])
    }

    @Test("A titleless first section joins the next titled one; with no titles at all the first bullet is the title")
    func titlelessSections() throws {
        let leading = try decode("""
        {"sections": [{"bullets": [{"text": "Early point"}]}, {"title": "Pricing", "bullets": [{"text": "Two tiers"}]}]}
        """)
        #expect(leading.sections.map(\.title) == ["Pricing"])
        #expect(leading.sections.first?.bullets.map(\.text) == ["Early point", "Two tiers"])

        let untitled = try decode("""
        {"sections": [{"title": "  ", "bullets": [{"text": "First point", "children": [{"text": "Detail"}]}, {"text": "Second point"}]}]}
        """)
        #expect(untitled.sections.map(\.title) == ["First point"])
        #expect(untitled.sections.first?.bullets.map(\.text) == ["Detail", "Second point"])
    }

    @Test("A bullet with only children hands them up")
    func childrenPromoted() throws {
        let summary = try decode("""
        {"sections": [{"title": "Plan", "bullets": [{"text": "", "children": [{"text": "A"}, {"text": "B"}]}]}]}
        """)
        #expect(summary.sections.first?.bullets.map(\.text) == ["A", "B"])
    }

    @Test("Other shapes models write: plain strings, other key names, objects as action items")
    func otherShapes() throws {
        let summary = try decode("""
        {"summary": 42, "clientFollowUp": ["not", "a", "string"],
         "sections": ["Bare title", {"heading": "Budget", "points": ["Approved", {"content": "Q4 review"}]}],
         "actionItems": [{"task": "Send the deck"}, 7, "Call Ivan"]}
        """)
        #expect(summary.summary == "Bare title")
        #expect(summary.clientFollowUp.isEmpty)
        #expect(summary.sections.map(\.title) == ["Bare title", "Budget"])
        #expect(summary.sections.last?.bullets.map(\.text) == ["Approved", "Q4 review"])
        #expect(summary.actionItems == ["Send the deck", "Call Ivan"])
    }

    @Test("What still fails says where, once, with no «cloud:» inside")
    func failureReasons() {
        do {
            _ = try CloudSummaryDTO.decode(from: "[1, 2]")
            Issue.record("expected a DecodeFailure")
        } catch let error as CloudSummaryDTO.DecodeFailure {
            #expect(error.reason.contains("the top level"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
        do {
            _ = try CloudSummaryDTO.decode(from: #"{"summary": "cut", "sections": [}"#)
            Issue.record("expected a DecodeFailure")
        } catch let error as CloudSummaryDTO.DecodeFailure {
            #expect(error.reason.contains("not valid JSON"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
        let wrapped = SummaryProviderError.parseFailed(provider: "Anthropic", message: CloudSummaryDTO.DecodeFailure(reason: "JSON schema mismatch: the top level is not the expected type.").localizedDescription)
        let text = wrapped.localizedDescription
        #expect(!text.contains("cloud"))
        #expect(text.components(separatedBy: "JSON —").count == 2)
    }

    @Test("Log paths name positions and keys, never values")
    func paths() {
        let path = LenientJSON.path([LenientJSON.Key(stringValue: "sections"), LenientJSON.Key(intValue: 2)!, LenientJSON.Key(stringValue: "title")])
        #expect(path == "sections[2].title")
        #expect(LenientJSON.path([]) == "the top level")
    }

    @Test("Aliases are read straight off the keys, case ignored; a text task's follow_up is kept")
    func aliases() throws {
        let lede = try decode(#"{"LEDE": "Pricing call recap.", "Outline": [], "Action_Items": ["Call back"]}"#)
        #expect(lede.summary == "Pricing call recap.")
        #expect(lede.actionItems == ["Call back"])
        // Before 03.11 the alias retry judged emptiness without the
        // follow-up and handed back the reply without its text.
        let text = try decode(#"{"summary": "", "sections": [], "actionItems": [], "follow_up": "Привет, Пете"}"#)
        #expect(text.clientFollowUp == "Привет, Пете")
        #expect(try decode(#"{"clientFollowUp": "canonical", "follow_up": "alias"}"#).clientFollowUp == "canonical")
    }

    @Test("Among a field's names the first that holds something wins, and a value of the wrong type reads as absent")
    func firstNonEmpty() throws {
        let summary = try decode("""
        {"sections": "not a list", "outline": [{"title": "", "heading": "Budget", "bullets": [], "items": [{"text": "Approved"}]}]}
        """)
        #expect(summary.sections.map(\.title) == ["Budget"])
        #expect(summary.sections.first?.bullets.map(\.text) == ["Approved"])
    }

    @Test("A bullet written like a section keeps its heading as text")
    func sectionShapedBullet() throws {
        let summary = try decode("""
        {"sections": [{"title": "Plan", "bullets": [{"title": "Launch", "bullets": [{"text": "May"}]}]}]}
        """)
        let bullet = try #require(summary.sections.first?.bullets.first)
        #expect(bullet.text == "Launch")
        #expect(bullet.children.map(\.text) == ["May"])
    }

    @Test("The schema Anthropic gets is localModelJSON written out, in a fixed order")
    func constrainedSchema() throws {
        func object(_ text: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        // The same shape as the local model's, $refs inlined, annotations off.
        var local = try object(MeetingSummaryJSONSchema.localModelJSON)
        let definitions = try #require(local.removeValue(forKey: "$defs") as? [String: Any])
        local.removeValue(forKey: "$schema")
        local.removeValue(forKey: "$id")
        func inlined(_ node: Any) -> Any {
            if let object = node as? [String: Any] {
                if let ref = object["$ref"] as? String, let name = ref.split(separator: "/").last {
                    return inlined(definitions[String(name)] as Any)
                }
                return object.mapValues(inlined)
            }
            if let array = node as? [Any] { return array.map(inlined) }
            return node
        }
        let meetingText = MeetingSummaryJSONSchema.constrainedReplyJSON(includesTitle: true)
        let meeting = try object(meetingText)
        #expect(NSDictionary(dictionary: meeting).isEqual(to: inlined(local) as? [String: Any] ?? [:]))

        let other = try object(MeetingSummaryJSONSchema.constrainedReplyJSON(includesTitle: false))
        #expect(other["required"] as? [String] == ["summary", "sections", "actionItems", "clientFollowUp"])
        #expect((other["properties"] as? [String: Any])?["title"] == nil)

        // The order the model will write in: the envelope as the prompt
        // lays it out, a bullet's text before its children.
        let positions = ["\"title\"", "\"summary\"", "\"sections\"", "\"actionItems\"", "\"clientFollowUp\""]
            .compactMap { meetingText.range(of: $0)?.lowerBound }
        #expect(positions.count == 5 && positions == positions.sorted())
        #expect(meetingText.contains(#""text":{"type":"string"},"children""#))
        #expect(meetingText.contains(#""title":{"type":"string"},"bullets""#))
        // A reply in it is a reply the decoder reads.
        let reply = #"{"title":"T","summary":"S","sections":[{"title":"A","bullets":[{"text":"B","children":[{"text":"C"}]}]}],"actionItems":[],"clientFollowUp":""}"#
        #expect(try decode(reply).sections.first?.bullets.first?.children.first?.text == "C")
    }

    @Test("Only the meeting summary asks for a title")
    func titleTasks() {
        #expect(SummaryTask.meeting(forceFollowUp: true).asksForTitle)
        #expect(!SummaryTask.catchUp.asksForTitle)
        #expect(!SummaryTask.voiceProfile.asksForTitle)
        #expect(!SummaryTask.dictationPolish(instruction: "x").asksForTitle)
    }
}
