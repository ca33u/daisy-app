// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SpeakerNameSuggesterTests.swift
//  DaisyTests
//
//  A wrong speaker name is a quotation attributed to a real person who
//  didn't say it, and it propagates into the summary, the follow-up
//  draft, and anything auto-sent. The allow-list is what stops that,
//  so it gets the tests.
//

import Testing
import Foundation
@testable import Daisy

@Suite("Speaker name suggestions")
struct SpeakerNameSuggesterTests {

    private let roster = ["Priya Raman", "Alex Chen", "Марина Соколова"]

    private func context(labels: [String] = ["A", "B"]) -> SpeakerNameSuggester.PromptContext {
        .init(attendees: roster, labels: labels)
    }

    private func segment(
        _ text: String,
        source: SegmentSource,
        speaker: String? = nil,
        at offset: TimeInterval = 0
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            text: text,
            isFinal: true,
            source: source,
            speakerId: speaker
        )
    }

    // MARK: - Reply parsing

    @Test("Assignment lines parse; declined ones don't become names")
    func parse_readsAssignmentsAndSkipsDeclines() {
        let parsed = SpeakerNameSuggester.parseAssignments("""
        A = Priya Raman
        B =
        C = ?
        D = unknown
        """)
        #expect(parsed == ["A": "Priya Raman"])
    }

    @Test("Prose and bullets around the lines are tolerated")
    func parse_ignoresSurroundingProse() {
        let parsed = SpeakerNameSuggester.parseAssignments("""
        Based on the transcript:
        - A = Alex Chen
        Hope that helps!
        """)
        #expect(parsed == ["A": "Alex Chen"])
    }

    @Test("A label the reply contradicts itself about is dropped, not resolved by order")
    func parse_dropsContradictedLabel() {
        let parsed = SpeakerNameSuggester.parseAssignments("""
        A = Priya Raman
        B = Alex Chen
        A = Alex Chen
        """)
        // Keeping whichever came last would be picking a side at random.
        // B is untouched — a contradiction about one speaker says
        // nothing about the rest.
        #expect(parsed == ["B": "Alex Chen"])
    }

    @Test("A label repeated with the SAME name is not a contradiction")
    func parse_toleratesHarmlessRepeat() {
        #expect(SpeakerNameSuggester.parseAssignments("A = Priya Raman\nA = Priya Raman")
                == ["A": "Priya Raman"])
    }

    @Test("A sentence containing an equals sign isn't an assignment")
    func parse_requiresSingleLetterLabel() {
        #expect(SpeakerNameSuggester.parseAssignments("speaker one = Priya").isEmpty)
    }

    // MARK: - Allow-list

    @Test("A name from the invite is accepted")
    func filter_acceptsInviteName() {
        let accepted = SpeakerNameSuggester.filter(["A": "Priya Raman"], context: context())
        #expect(accepted == ["A": "Priya Raman"])
    }

    @Test("A given name resolves to the invite's spelling")
    func filter_resolvesGivenName() {
        // People say first names in meetings; dropping those would
        // discard most of what this pass is for.
        let accepted = SpeakerNameSuggester.filter(["A": "priya"], context: context())
        #expect(accepted == ["A": "Priya Raman"])
    }

    @Test("A name that isn't on the invite is discarded")
    func filter_rejectsUninvitedName() {
        // The model's single most dangerous move: naming someone who was
        // merely TALKED ABOUT. No prompt wording can be trusted to
        // prevent it, so the allow-list does.
        #expect(SpeakerNameSuggester.filter(["A": "Sarah"], context: context()).isEmpty)
        #expect(SpeakerNameSuggester.filter(["A": "Priya Sharma"], context: context()).isEmpty)
    }

    @Test("An embellished name is not treated as a prefix match")
    func filter_rejectsEmbellishedName() {
        // "Priya Raman from Acme" must not slip through as a bare given
        // name would — only a single-word proposal gets prefix matching.
        #expect(SpeakerNameSuggester.filter(["A": "Priya Raman from Acme"], context: context()).isEmpty)
    }

    @Test("An ambiguous given name is discarded rather than guessed")
    func filter_rejectsAmbiguousGivenName() {
        let twoPriyas = SpeakerNameSuggester.PromptContext(
            attendees: ["Priya Raman", "Priya Nair"],
            labels: ["A"]
        )
        #expect(SpeakerNameSuggester.filter(["A": "Priya"], context: twoPriyas).isEmpty)
    }

    @Test("A label that isn't in this meeting is discarded")
    func filter_rejectsUnknownLabel() {
        #expect(SpeakerNameSuggester.filter(["Z": "Alex Chen"], context: context()).isEmpty)
    }

    @Test("The same person behind two labels means neither is offered")
    func filter_rejectsDuplicateAssignment() {
        // Assigning one person to two voices proves it guessed at least
        // once, and there's no way to tell which.
        let accepted = SpeakerNameSuggester.filter(
            ["A": "Alex Chen", "B": "alex"],
            context: context()
        )
        #expect(accepted.isEmpty)
    }

    @Test("A duplicate doesn't take unrelated suggestions down with it")
    func filter_keepsOtherLabelsWhenOneNameCollides() {
        let accepted = SpeakerNameSuggester.filter(
            ["A": "Alex Chen", "B": "alex", "C": "Priya Raman"],
            context: .init(attendees: roster, labels: ["A", "B", "C"])
        )
        #expect(accepted == ["C": "Priya Raman"])
    }

    @Test("Names match across case and spacing, including Cyrillic")
    func filter_normalizesNames() {
        let accepted = SpeakerNameSuggester.filter(
            ["A": "  марина   соколова "],
            context: context(labels: ["A"])
        )
        #expect(accepted == ["A": "Марина Соколова"])
    }

    // MARK: - Transcript sampling

    @Test("Remote turns carry their label; the user's turns don't")
    func sampling_labelsRemoteTurnsOnly() {
        let sample = SpeakerNameSuggester.sampleTranscript([
            segment("спасибо, Прия", source: .microphone, at: 0),
            segment("да, конечно", source: .systemAudio, speaker: "A", at: 1),
        ])
        // The vocative is usually spoken BY the user, so their turns
        // have to be visible — they just have no label to propose.
        #expect(sample == "—: спасибо, Прия\nA: да, конечно")
    }

    @Test("A remote turn with no cluster still appears, marked unknown")
    func sampling_marksUnclusteredRemoteTurns() {
        let sample = SpeakerNameSuggester.sampleTranscript([
            segment("привет всем", source: .systemAudio, speaker: nil),
        ])
        #expect(sample == "?: привет всем")
    }

    @Test("An over-budget transcript is sampled from both ends")
    func sampling_takesHeadAndTail() {
        // Introductions are at the top and goodbyes at the bottom; the
        // middle of a meeting is where names are used least.
        var segments: [TranscriptSegment] = [
            segment("здравствуйте это Прия", source: .systemAudio, speaker: "A", at: 0)
        ]
        for index in 1...60 {
            segments.append(segment(
                String(repeating: "нусреднийразговор ", count: 12),
                source: .systemAudio,
                speaker: "B",
                at: Double(index)
            ))
        }
        segments.append(segment("спасибо Прия до встречи", source: .microphone, at: 100))

        let sample = SpeakerNameSuggester.sampleTranscript(segments, budget: 2_000)
        #expect(sample.count <= 2_100)
        #expect(sample.contains("здравствуйте это Прия"))
        #expect(sample.contains("спасибо Прия до встречи"))
        #expect(sample.contains("[…]"))
    }

    @Test("A single utterance bigger than the budget is truncated, not dropped")
    func sampling_truncatesOneOversizedSegment() {
        // Both the head and the tail loop break on the first line here.
        // Returning "" would skip the pass on a short call where VAD
        // never split the audio — silently, with nothing in the log.
        let sample = SpeakerNameSuggester.sampleTranscript(
            [segment(String(repeating: "с", count: 5_000), source: .systemAudio, speaker: "A")],
            budget: 500
        )
        #expect(sample.count == 500)
        #expect(sample.hasPrefix("A: "))
    }

    @Test("A transcript that fits is passed through whole, with no elision marker")
    func sampling_passesShortTranscriptThrough() {
        let sample = SpeakerNameSuggester.sampleTranscript([
            segment("привет", source: .systemAudio, speaker: "A", at: 0),
            segment("здравствуй", source: .microphone, at: 1),
        ])
        #expect(!sample.contains("[…]"))
        #expect(sample == "A: привет\n—: здравствуй")
    }

    @Test("Blank segments are dropped and newlines flattened")
    func sampling_cleansSegments() {
        let sample = SpeakerNameSuggester.sampleTranscript([
            segment("   ", source: .systemAudio, speaker: "A", at: 0),
            segment("первая\nвторая", source: .systemAudio, speaker: "B", at: 1),
        ])
        #expect(sample == "B: первая вторая")
    }

    // MARK: - Prompt

    /// Collapse whitespace so assertions test what the prompt SAYS, not
    /// where its lines happen to wrap — otherwise re-flowing a
    /// paragraph breaks a test that should not care.
    private func flattened(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    @Test("The prompt carries the roster, the labels, and the empty-answer license")
    func prompt_statesRosterAndPermissionToDecline() {
        let instructions = flattened(SummaryPrompt.speakerNamesSystemInstructions(context: context()))
        #expect(instructions.contains("Priya Raman"))
        #expect(instructions.contains("A, B"))
        // "Say nothing" has to read as a correct answer, or the model
        // spends its one shot guessing.
        #expect(instructions.contains("Empty is a correct, expected, and common answer"))
        #expect(instructions.contains("A ="))
    }

    @Test("The freeform variant keeps the rules and drops the JSON envelope")
    func prompt_freeformKeepsRules() {
        let json = flattened(SummaryPrompt.speakerNamesSystemInstructions(context: context()))
        let freeform = flattened(
            SummaryPrompt.speakerNamesSystemInstructions(context: context(), jsonEnvelope: false)
        )
        #expect(json.contains("clientFollowUp"))
        #expect(!freeform.contains("clientFollowUp"))
        for rule in [
            "Never invent a name",
            "A name being mentioned is not evidence of who is SPEAKING",
            "Empty is a correct, expected, and common answer",
            "Never assign the same person to two different labels",
            "Priya Raman",
        ] {
            #expect(json.contains(rule))
            #expect(freeform.contains(rule))
        }
    }

    // MARK: - Reading back a rename made mid-pipeline

    /// Write `markdown` to a throwaway transcript.md and read its
    /// speaker map back the way the post-stop pipeline does.
    private func speakerMap(inTranscript markdown: String) throws -> [String: String] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("daisy-speakermap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcript.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return RecordingSession.persistedSpeakerMap(at: url)
    }

    @Test("A speaker map in the frontmatter is read back")
    func persistedMap_readsFrontmatter() throws {
        // This is how a rename the user makes WHILE the post-stop
        // pipeline is still running reaches us — it's written to
        // transcript.md, not to the in-memory session.
        let map = try speakerMap(inTranscript: """
        ---
        title: "Sync"
        daisy_speaker_map: {A: "Priya Raman", B: "Alex Chen"}
        ---

        ## Transcript

        **[00:01 · Remote A]** привет
        """)
        #expect(map == ["A": "Priya Raman", "B": "Alex Chen"])
    }

    @Test("An empty map and a missing key both read as no names")
    func persistedMap_handlesEmptyAndAbsent() throws {
        #expect(try speakerMap(inTranscript: "---\ndaisy_speaker_map: {}\n---\n\nbody").isEmpty)
        #expect(try speakerMap(inTranscript: "---\ntitle: \"Sync\"\n---\n\nbody").isEmpty)
        #expect(try speakerMap(inTranscript: "no frontmatter here").isEmpty)
    }

    @Test("A body line that looks like the key is not parsed as one")
    func persistedMap_ignoresBodyLines() throws {
        // Someone reading a transcript aloud, or an OCR'd slide, can put
        // this text in the body. Reading it would invent names.
        let map = try speakerMap(inTranscript: """
        ---
        title: "Sync"
        ---

        ## Transcript

        **[00:01 · Remote A]** daisy_speaker_map: {A: "Wrong Person"}
        """)
        #expect(map.isEmpty)
    }

    // MARK: - Merge rules

    @Test("The fuller written form wins; a short form never absorbs a long one")
    func matching_isOneWay() {
        // "Priya" resolves UP to "Priya Raman"…
        #expect(SpeakerNameMatching.resolve("Priya", in: ["Priya Raman"]) == "Priya Raman")
        // …but a roster holding only the stub can't absorb the full name.
        #expect(SpeakerNameMatching.resolve("Priya Raman", in: ["Priya"]) == nil)
    }

    @Test("Spaceless forms match only when the parts are too long to be initials")
    func matching_spacelessNeedsLongParts() {
        #expect(SpeakerNameMatching.resolve("PriyaRaman", in: ["Priya Raman"]) == "Priya Raman")
        #expect(SpeakerNameMatching.resolve("priya raman", in: ["PriyaRaman"]) == "PriyaRaman")
        // "AJ" ↔ "A J" is initials, not a spelling variant.
        #expect(SpeakerNameMatching.resolve("AJ", in: ["A J"]) == nil)
        #expect(SpeakerNameMatching.resolve("Jo Li", in: ["JoLi"]) == nil)
    }

    @Test("Any ambiguity resolves to no match, never to a best guess")
    func matching_refusesAmbiguity() {
        #expect(SpeakerNameMatching.resolve("Priya", in: ["Priya Raman", "Priya Nair"]) == nil)
        #expect(SpeakerNameMatching.resolve("alex", in: ["Alex Chen", "Alex Rivera"]) == nil)
        // Roster entries that are the same name written two ways are a
        // duplicate, not an ambiguity.
        #expect(SpeakerNameMatching.resolve("Alex", in: ["alex", "ALEX  "]) == "alex")
    }

    @Test("A tier that finds two answers stops the search — it doesn't hand down to a weaker one")
    func matching_ambiguityDoesNotFallThrough() {
        // The spaceless tier matches both "Priya Raman" and "Pri Yaraman"
        // here. Letting that ambiguity fall through to the given-name
        // tier would answer with a THIRD person, confidently.
        #expect(SpeakerNameMatching.resolve(
            "PriyaRaman",
            in: ["Priya Raman", "Pri Yaraman", "Priyaraman Kumar"]
        ) == nil)
    }

    @Test("A one-letter given name is not enough to resolve a full name")
    func matching_rejectsInitialAsGivenName() {
        #expect(SpeakerNameMatching.resolve("A", in: ["A Kuznetsov"]) == nil)
        #expect(SpeakerNameMatching.resolve("Ann", in: ["Ann Kuznetsova"]) == "Ann Kuznetsova")
    }

    @Test("Case and spacing differences are not differences")
    func matching_normalizes() {
        #expect(SpeakerNameMatching.resolve("  МАРИНА   соколова ", in: ["Марина Соколова"]) == "Марина Соколова")
        #expect(SpeakerNameMatching.sameName("Priya Raman", "priya  raman"))
        #expect(!SpeakerNameMatching.sameName("Priya Raman", "Alex Chen"))
    }

    // MARK: - "Never guess" evidence

    private func turn(_ label: String?, _ text: String) -> SpeakerNameSuggester.Turn {
        .init(label: label, text: text)
    }

    @Test("A self-introduction is enough on its own")
    func evidence_acceptsSelfIntroduction() {
        // Nobody introduces themselves as someone else.
        let turns = [
            turn(nil, "привет, начнём"),
            turn("A", "привет, это Прия, я по проекту"),
        ]
        #expect(SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Прия", turns: turns))
        #expect(SpeakerNameSuggester.hasNamingEvidence(
            label: "A", name: "Priya Raman",
            turns: [turn("A", "hi, this is Priya, I'm covering the design side")]
        ))
    }

    @Test("Saying a name in your own turn is not introducing yourself as them")
    func evidence_rejectsSelfMentionOfSomeoneElse() {
        // Without an introduction cue this certifies whoever said it AS
        // Priya, for the crime of mentioning her.
        let turns = [
            turn(nil, "how did the deck go?"),
            turn("A", "I'll check with Priya and get back to you"),
        ]
        #expect(!SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Priya Raman", turns: turns))
    }

    @Test("Being addressed twice next to your own turn is enough")
    func evidence_acceptsRepeatedAddress() {
        let turns = [
            turn(nil, "спасибо, Прия"),
            turn("A", "не за что"),
            turn(nil, "и ещё, Прия, посмотри макеты"),
            turn("A", "хорошо"),
        ]
        #expect(SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Прия", turns: turns))
    }

    @Test("Being addressed once is a coincidence, not evidence")
    func evidence_rejectsSingleAddress() {
        let turns = [
            turn(nil, "спасибо, Прия"),
            turn("A", "не за что"),
        ]
        #expect(!SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Прия", turns: turns))
    }

    @Test("A name merely discussed is not evidence about who is speaking")
    func evidence_rejectsThirdPartyMentions() {
        // The single most common way to get this wrong: people talk
        // about absent colleagues constantly. Every mention here sits
        // DIRECTLY beside A's turns and still must not count, because
        // none of them is addressing anyone.
        let turns = [
            turn("C", "did you send Priya the deck?"),
            turn("A", "not yet"),
            turn("C", "Priya needs it today"),
            turn("A", "ok"),
            turn("C", "I'll ask Priya."),
            turn("A", "sure"),
        ]
        #expect(!SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Priya Raman", turns: turns))
    }

    @Test("Vocative position is what separates addressing someone from discussing them")
    func evidence_vocativeDetection() {
        #expect(SpeakerNameSuggester.isVocative("прия", in: "спасибо, Прия"))
        #expect(SpeakerNameSuggester.isVocative("прия", in: "Прия, посмотри макеты"))
        #expect(SpeakerNameSuggester.isVocative("прия", in: "и ещё, Прия, глянь сроки"))
        #expect(!SpeakerNameSuggester.isVocative("priya", in: "did you send Priya the deck?"))
        #expect(!SpeakerNameSuggester.isVocative("priya", in: "Priya needs it today"))
        #expect(!SpeakerNameSuggester.isVocative("priya", in: "I'll ask Priya."))
    }

    @Test("Mentions match whole tokens, not substrings")
    func evidence_matchesWholeTokens() {
        #expect(SpeakerNameSuggester.mentions("alex", in: "thanks, Alex!"))
        #expect(!SpeakerNameSuggester.mentions("alex", in: "Alexander will send it"))
        #expect(SpeakerNameSuggester.mentions("priya raman", in: "cc Priya Raman please"))
        #expect(!SpeakerNameSuggester.mentions("прия", in: "Прияткин звонил"))
    }

    @Test("Names with apostrophes and hyphens are matchable")
    func evidence_matchesPunctuatedNames() {
        // Splitting the needle on spaces alone left the apostrophe in it
        // and stripped it from the text, so every O'Brien, Anne-Marie
        // and Jean-Luc silently failed to match anything.
        #expect(SpeakerNameSuggester.mentions("o'brien", in: "thanks, O'Brien"))
        #expect(SpeakerNameSuggester.mentions("anne-marie", in: "Anne-Marie, can you check?"))
        #expect(SpeakerNameSuggester.mentions("jean-luc picard", in: "cc Jean-Luc Picard"))
        #expect(SpeakerNameSuggester.isVocative("o'brien", in: "thanks, O'Brien"))
    }

    @Test("A full name and its given name both count as the same person being named")
    func evidence_acceptsGivenNameForm() {
        let turns = [
            turn(nil, "Priya, can you take that?"),
            turn("A", "sure"),
            turn(nil, "thanks, Priya"),
            turn("A", "no problem"),
        ]
        #expect(SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Priya Raman", turns: turns))
        // A two-letter given name isn't used as a form on its own — too
        // easy to collide with an ordinary word.
        #expect(SpeakerNameSuggester.nameForms("Jo Li") == ["jo li"])
    }

    @Test("Being addressed once is still not enough, even in vocative position")
    func evidence_stillRequiresTwoAddresses() {
        let turns = [
            turn(nil, "Priya, can you take that?"),
            turn("A", "sure"),
        ]
        #expect(!SpeakerNameSuggester.hasNamingEvidence(label: "A", name: "Priya Raman", turns: turns))
    }

    // MARK: - Profile name matching

    @Test("Profile names normalize across case and spacing")
    func profileNames_normalize() {
        #expect(SpeakerNameMatching.normalize("  Priya   Raman ") == "priya raman")
        #expect(SpeakerNameMatching.normalize("PRIYA RAMAN") == "priya raman")
        #expect(SpeakerNameMatching.normalize("   ") == nil)
        // Deliberately NOT equal — no diacritic folding, no nicknames.
        // A wrong speaker name is worse than "Remote B".
        #expect(SpeakerNameMatching.normalize("Renée") != SpeakerNameMatching.normalize("Renee"))
    }
}
