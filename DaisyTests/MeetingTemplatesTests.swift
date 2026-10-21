//
//  MeetingTemplatesTests.swift
//  DaisyTests
//
//  Backlog 35: the rule that picks a template, the transcript the pass
//  reads, the check on what it gives back, and summary.json staying
//  readable with the new keys — on the Mac's type and DaisyCore's.
//

import DaisyCore
import Foundation
import Testing
@testable import Daisy

struct MeetingTemplatesTests {
    private func summaryTemplate(_ name: String, folders: [String] = [], words: [String] = [], isDefault: Bool = false) -> MeetingTemplate {
        var t = MeetingTemplate(kind: .summary, name: name, sections: [MeetingTemplateSection(title: "A")],
                                folderSlugs: folders, titleWords: words)
        t.isDefault = isDefault
        return t
    }

    // MARK: Choosing

    @Test func pickedByHandBeatsFolderBeatsTitleBeatsDefault() {
        let sales = summaryTemplate("Sales", folders: ["sales"])
        let interview = summaryTemplate("Interview", words: ["интервью"])
        let fallback = summaryTemplate("Default", isDefault: true)
        let all = [sales, interview, fallback]

        let byHand = MeetingTemplateChoice.choose(.summary, among: all, picked: interview.id.uuidString,
                                                  folderSlug: "sales", title: "Интервью")
        #expect(byHand?.template.id == interview.id && byHand?.reason == .pickedByHand)

        let byFolder = MeetingTemplateChoice.choose(.summary, among: all, folderSlug: "sales", folderName: "Продажи",
                                                    title: "Интервью с Анной")
        #expect(byFolder?.template.id == sales.id && byFolder?.reason == .folder("Продажи"))

        let byTitle = MeetingTemplateChoice.choose(.summary, among: all, folderSlug: "inbox", title: "Интервью с Анной")
        #expect(byTitle?.template.id == interview.id && byTitle?.reason == .titleWord("интервью"))

        let byDefault = MeetingTemplateChoice.choose(.summary, among: all, folderSlug: nil, title: "Weekly sync")
        #expect(byDefault?.template.id == fallback.id && byDefault?.reason == .byDefault)

        #expect(MeetingTemplateChoice.choose(.summary, among: [sales, interview], folderSlug: nil, title: "Sync") == nil)
    }

    @Test func archivedAndOtherKindsDontApply() {
        var archived = summaryTemplate("Old", words: ["demo"])
        archived.archived = true
        let followUp = MeetingTemplate(kind: .followUp, name: "Letter", structure: "x", titleWords: ["demo"])
        #expect(MeetingTemplateChoice.choose(.summary, among: [archived, followUp], folderSlug: nil, title: "Demo") == nil)
        #expect(MeetingTemplateChoice.choose(.followUp, among: [archived, followUp], folderSlug: nil, title: "Demo")?.template.id == followUp.id)
    }

    @Test func titleWordsMatchWordStartsAndLiteralTokens() {
        #expect(MeetingTemplateChoice.titleMentions("Интервью с Анной", "интервью"))
        #expect(MeetingTemplateChoice.titleMentions("Собеседование: Иван", "собеседован"))
        #expect(MeetingTemplateChoice.titleMentions("Demo — Acme", "DEMO"))
        #expect(MeetingTemplateChoice.titleMentions("Anna / Egor 1:1", "1:1"))
        #expect(!MeetingTemplateChoice.titleMentions("Redemo planning", "demo"))
        #expect(!MeetingTemplateChoice.titleMentions("Weekly", ""))
        // «1:1» is itself, not part of a time.
        #expect(!MeetingTemplateChoice.titleMentions("Sync 21:10", "1:1"))
        #expect(!MeetingTemplateChoice.titleMentions("Call at 11:15", "1:1"))
    }

    @Test func aDaisyKeyRequestNamesATemplateByWhatSetsItApart() {
        let sale = MeetingTemplate(kind: .followUp, name: "Клиенту после продажи", structure: "x")
        let candidate = MeetingTemplate(kind: .followUp, name: "Кандидату после интервью", structure: "y")
        let all = [sale, candidate]
        #expect(MeetingTemplateStore.template(mentionedIn: "напиши фоллоап Ивану по шаблону продажи", among: all)?.id == sale.id)
        #expect(MeetingTemplateStore.template(mentionedIn: "ответь по шаблону интервью", among: all)?.id == candidate.id)
        // «после» names both: nothing is picked from it alone.
        #expect(MeetingTemplateStore.template(mentionedIn: "по шаблону после", among: all) == nil)
        #expect(MeetingTemplateStore.template(mentionedIn: "напиши письмо Ивану", among: all) == nil)
    }

    // MARK: The pass

    private let markdown = """
    # Interview

    ## Transcript

    **[0:05 · Egor]** Расскажи про последний проект.

    **[0:12 · Remote A]** Я вёл миграцию платёжки, полгода.

    **[1:02:03 · Remote A]** Хочу 300 тысяч.

    ## Screenshots
    **[9:99 · nobody]** not a line
    """

    @Test func transcriptLinesKeepTheFilesTimecodes() {
        let lines = MeetingTemplatePass.transcriptLines(fromMarkdown: markdown)
        #expect(lines == """
        [0:05] Egor: Расскажи про последний проект.
        [0:12] Remote A: Я вёл миграцию платёжки, полгода.
        [1:02:03] Remote A: Хочу 300 тысяч.
        """)
        #expect(MeetingTemplatePass.timecodes(in: lines) == [5, 12, 3723])
        #expect(MeetingTemplatePass.transcriptLines(fromMarkdown: "no transcript here").isEmpty)
    }

    @Test func leadingTimecodes() {
        #expect(MeetingTemplatePass.leadingTimecode("[0:12] text") == 12)
        #expect(MeetingTemplatePass.leadingTimecode("[1:02:03] text") == 3723)
        #expect(MeetingTemplatePass.leadingTimecode("text [0:12]") == nil)
        #expect(MeetingTemplatePass.leadingTimecode("[ab] text") == nil)
    }

    @Test func onlyPointsTiedToTheTranscriptStay() {
        let template = [
            MeetingTemplateSection(title: "Опыт"),
            MeetingTemplateSection(title: "Деньги"),
            MeetingTemplateSection(title: "Сомнения"),
        ]
        let reply = """
        ## Опыт
        - [0:12] Вёл миграцию платёжки полгода
        - Сильный кандидат
        - [0:13] Строки с таким таймкодом нет
        ## Деньги
        - [1:02:03] Ожидания 300 тысяч
        - [9:00:00] За пределами встречи
        ## Сомнения
        - Не обсуждалось
        """
        let sections = MeetingTemplatePass.parse(reply, template: template, notDiscussed: "Не обсуждалось",
                                                 knownTimecodes: [5, 12, 3723], durationSec: 3800)
        #expect(sections.map(\.title) == ["Опыт", "Деньги", "Сомнения"])
        #expect(sections[0].bullets.map(\.text) == ["[0:12] Вёл миграцию платёжки полгода"])
        #expect(sections[1].bullets.map(\.text) == ["[1:02:03] Ожидания 300 тысяч"])
        #expect(sections[2].bullets.map(\.text) == ["Не обсуждалось"])
    }

    @Test func headingsMatchByNumberOrTitleNotByPosition() {
        let template = [MeetingTemplateSection(title: "A"), MeetingTemplateSection(title: "B"),
                        MeetingTemplateSection(title: "C")]
        // An extra heading on top, B skipped, the timecode written «05:12».
        let reply = """
        ## Notes
        - [0:01] stray
        ## 1. A
        - [05:12] first
        ## 3. C
        - [5:20] third
        """
        let sections = MeetingTemplatePass.parse(reply, template: template, notDiscussed: "Not discussed",
                                                 knownTimecodes: [312, 320], durationSec: 600)
        #expect(sections.map(\.title) == ["A", "B", "C"])
        #expect(sections[0].bullets.map(\.text) == ["[05:12] first"])
        #expect(sections[1].bullets.map(\.text) == ["Not discussed"])
        #expect(sections[2].bullets.map(\.text) == ["[5:20] third"])
    }

    @Test func translatedTitlesKeepTheirPlaces() {
        let template = [MeetingTemplateSection(title: "Pains"), MeetingTemplateSection(title: "Budget"),
                        MeetingTemplateSection(title: "Next step")]
        // No numbers; one title kept, two translated; a marker in a title.
        let reply = """
        ## Боли
        - [0:05] Долгий онбординг
        ## Budget
        - [0:10] 40k
        ## [[DAISY_ORGANIZATION_001]] шаг
        - [0:20] Демо в пятницу
        """
        let sections = MeetingTemplatePass.parse(reply, template: template, notDiscussed: "Not discussed",
                                                 knownTimecodes: [5, 10, 20], durationSec: 60)
        #expect(sections.map(\.title) == ["Боли", "Budget", "Next step"])
        #expect(sections.map { $0.bullets.first?.text } == ["[0:05] Долгий онбординг", "[0:10] 40k", "[0:20] Демо в пятницу"])
    }

    @Test func aPointWithALeftoverMarkerGoesAlone() {
        let template = [MeetingTemplateSection(title: "A")]
        let sections = MeetingTemplatePass.parse("## 1. A\n- [0:05] call [[DAISY_PERSON_002]]\n- [0:06] fine",
                                                 template: template, notDiscussed: "Not discussed",
                                                 knownTimecodes: [5, 6], durationSec: 60)
        #expect(sections[0].bullets.map(\.text) == ["[0:06] fine"])
    }

    @Test func aMissingSectionSaysNotDiscussedUnderTheTemplatesTitle() {
        let template = [MeetingTemplateSection(title: "Pains"), MeetingTemplateSection(title: "Budget")]
        let sections = MeetingTemplatePass.parse("## Pains\n- [0:05] Slow onboarding", template: template,
                                                 notDiscussed: "Not discussed", knownTimecodes: [5], durationSec: 60)
        #expect(sections.count == 2)
        #expect(sections[1].title == "Budget")
        #expect(sections[1].bullets.map(\.text) == ["Not discussed"])
    }

    @Test func notDiscussedFollowsTheMeetingsLanguage() {
        #expect(MeetingTemplatePass.notDiscussed(language: "ru") == "Не обсуждалось")
        #expect(MeetingTemplatePass.notDiscussed(language: "en") == "Not discussed")
        #expect(MeetingTemplatePass.notDiscussed(language: nil) == "Not discussed")
    }

    @Test func thePromptCarriesTheSectionsAndTheRules() {
        let context = TemplatedSummaryContext(
            sections: [MeetingTemplateSection(title: "Боли", hint: "своими словами"), MeetingTemplateSection(title: "Бюджет")],
            notDiscussed: "Не обсуждалось")
        let rules = SummaryPrompt.templatedSummaryRules(context, localeHint: nil)
        #expect(rules.contains("1. Боли — своими словами"))
        #expect(rules.contains("2. Бюджет"))
        #expect(rules.contains("Не обсуждалось"))
        #expect(rules.contains("timecode"))
        #expect(rules.contains("language the meeting was held in"))
    }

    // MARK: Reading examples

    @Test func sectionLinesFromAReading() {
        let sections = MeetingTemplatePass.sectionLines("""
        1. Ситуация клиента — чем занимаются
        - Боли: своими словами
        ## Следующий шаг
        """)
        #expect(sections.map(\.title) == ["Ситуация клиента", "Боли", "Следующий шаг"])
        #expect(sections.map(\.hint) == ["чем занимаются", "своими словами", ""])
    }

    @Test func aMarkerThatCameBackIsNotPutBack() {
        #expect(MeetingTemplatePass.withoutMarkers("Greet [[DAISY_PERSON_001]] by name") == "Greet … by name")
        #expect(MeetingTemplatePass.withoutMarkers("Key [[REDACTED_SECRET]]") == "Key …")
        #expect(MeetingTemplatePass.withoutMarkers("Greet [[ daisy_person_001 ]]") == "Greet …")
        #expect(MeetingTemplatePass.withoutNames("Hi Ivan Petrov, from Acme", ["Ivan Petrov", "Acme"]) == "Hi …, from …")
        #expect(MeetingTemplatePass.withoutNames("Ann sent the annual plan", ["Ann"]) == "… sent the annual plan")
    }

    @Test func examplesGoOutWithPlainLabels() {
        #expect(MeetingTemplatePass.genericLabels("Hi [[DAISY_PERSON_001]], mail [[DAISY_EMAIL_002]]; [[REDACTED_SECRET]]")
                == "Hi [person], mail [email]; [secret]")
    }

    @Test func aMailWithAnAttachmentAndAKoi8Body() throws {
        let koi8 = try #require("Привет".data(using: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))))
        let encoded = koi8.base64EncodedString()
        let eml = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain; charset=koi8-r
        Content-Transfer-Encoding: base64

        \(encoded)
        --inner
        Content-Type: text/html

        <p>no</p>
        --inner--
        --outer
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64

        JVBERi0=
        --outer--
        """
        #expect(TemplateExampleFile.emailBody(eml) == "Привет")
    }

    @Test func anEmlGivesItsPlainBody() {
        let eml = """
        From: Anna <anna@example.com>
        Subject: =?utf-8?Q?Follow-up?=
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Hi Ivan,=0Athanks for the call =E2=80=94 here's the plan.
        > On Monday Ivan wrote:
        > quoted
        --b1
        Content-Type: text/html

        <p>html</p>
        --b1--
        """
        let body = TemplateExampleFile.emailBody(eml)
        #expect(body.contains("Hi Ivan,\nthanks for the call — here's the plan."))
        #expect(!body.contains("quoted"))
        #expect(!body.contains("<p>"))
    }

    @Test func an8bitKoi8MailFileReadsInRussian() throws {
        let koi8 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        var data = Data("Content-Type: text/plain; charset=koi8-r\nContent-Transfer-Encoding: 8bit\n\n".utf8)
        data.append(try #require("Добрый день, Иван".data(using: koi8)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("b35-\(UUID().uuidString).eml")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TemplateExampleFile.text(of: url) == "Добрый день, Иван")
    }

    // MARK: summary.json

    @Test func templatedSurvivesTheMacsSummaryType() throws {
        var summary = Daisy.MeetingSummary(summary: "Lede", actionItems: ["Send"], clientFollowUp: "Hi")
        summary.templated = Daisy.TemplatedSummary(template: "Interview", templateID: "id", reason: "folder “Hiring”",
                                                   pickedByHand: true,
                                                   sections: [Daisy.SummarySection(title: "Опыт", bullets: [Daisy.SummaryBullet(text: "[0:12] x")])])
        summary.followUpTemplate = Daisy.TemplateReference(name: "Sales", id: "t", pickedByHand: nil)
        let decoded = try JSONDecoder().decode(Daisy.MeetingSummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded == summary)

        // An old file, and one whose `templated` this version can't read.
        let old = try JSONDecoder().decode(Daisy.MeetingSummary.self, from: Data(#"{"summary":"x"}"#.utf8))
        #expect(old.templated == nil && old.followUpTemplate == nil)
        let odd = try JSONDecoder().decode(Daisy.MeetingSummary.self,
                                           from: Data(#"{"summary":"x","templated":{"sections":7}}"#.utf8))
        #expect(odd.summary == "x" && odd.templated == nil)
    }

    @Test func templatedSurvivesAPhoneStatusWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b35-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"""
        {"summary":"x","sections":[],"actionItems":["Send"],"clientFollowUp":"",
         "templated":{"template":"Interview","sections":[{"title":"Опыт","bullets":[{"text":"[0:12] x","children":[]}]}]},
         "followUpTemplate":{"name":"Sales"}}
        """#
        try Data(json.utf8).write(to: SummaryStore.url(in: dir))
        let id = try #require(SummaryStore.read(from: dir)?.actions.first?.id)
        SummaryStore.setStatus(nil, forAction: id, in: dir)
        let after = try #require(SummaryStore.read(from: dir))
        #expect(after.templated?.template == "Interview")
        #expect(after.templated?.sections.first?.bullets.first?.text == "[0:12] x")
        #expect(after.followUpTemplate?.name == "Sales")
    }
}
