//
//  TranscriptPolisherCorpusTests.swift
//  DaisyTests
//
//  The polish guards are a TRADE, and a trade can only be judged in
//  bulk. Tight guards fail quietly: a pass that rejects every chunk
//  looks exactly like a pass that is working, which is precisely what
//  happened to Russian — the feature shipped, ran on every meeting, and
//  changed nothing, because restoring «фигма» → "Figma" cost a token
//  while the identical English fix "figma" → "Figma" cost nothing.
//
//  So the corpus lives in `scripts/polish-corpus/corpus.json` and every
//  case declares which side it must land on:
//
//    • `accept` — a polish the pass MUST ship. Brand and name
//      restoration across scripts, punctuation, casing, and the
//      no-op chunk a good model correctly leaves alone.
//    • `drop` — a trap it MUST refuse. Paraphrase, condensation,
//      invented clauses, translation, swapped lines, tampered numbers,
//      inverted polarity, the model's own sign-off, and the two attacks
//      aimed squarely at the 2026-08-25 calibration: replacing an
//      utterance with sanctioned vocabulary, and swapping one attendee's
//      name for another's.
//
//  Both halves matter equally. Raising the accept rate by loosening a
//  guard shows up immediately as a trap getting through, which is the
//  only honest way to tune this.
//
//  The same JSON is read by `scripts/polish-corpus/check_corpus.py`,
//  a re-implementation used for fast threshold work when Xcode isn't
//  available. THIS file is the authority; if the two disagree, the
//  Python one is stale.
//

import Testing
import Foundation
@testable import Daisy

@Suite("Transcript polish regression corpus")
struct TranscriptPolisherCorpusTests {

    // MARK: - Corpus

    private struct Corpus: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let lang: String
        /// "accept" | "drop"
        let expect: String
        let why: String
        let raw: [String]
        /// The polished lines, rendered into a numbered reply. Absent
        /// when the trap is in the reply's SHAPE and `reply` carries it
        /// verbatim instead.
        let polished: [String]?
        let reply: String?
        let context: CaseContext?

        var mustAccept: Bool { expect == "accept" }

        var renderedReply: String {
            if let reply { return reply }
            return (polished ?? []).enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }

        var sanctioned: TranscriptPolisher.SanctionedTerms {
            TranscriptPolisher.SanctionedTerms(
                context: .init(
                    attendees: context?.attendees ?? [],
                    vocabulary: context?.vocabulary ?? [],
                    meetingApp: nil
                )
            )
        }
    }

    private struct CaseContext: Decodable {
        let attendees: [String]
        let vocabulary: [String]
    }

    /// Loaded from the source tree rather than a bundled resource: the
    /// corpus is shared with a script that lives outside the test target,
    /// and one copy is the whole point.
    private static func loadCorpus() throws -> [Case] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
        let url = repository
            .appendingPathComponent("scripts")
            .appendingPathComponent("polish-corpus")
            .appendingPathComponent("corpus.json")
        guard let data = try? Data(contentsOf: url) else {
            // `#filePath` bakes in the compile-time path, so a bundle run
            // from somewhere else fails here with an opaque error unless
            // we say what we were looking for.
            throw CorpusError.missing(url.path)
        }
        return try JSONDecoder().decode(Corpus.self, from: data).cases
    }

    private enum CorpusError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let path):
                return "Polish corpus not found at \(path) — the tests read it from the "
                    + "source tree, not from the test bundle."
            }
        }
    }

    private func run(_ testCase: Case) -> [UUID: String]? {
        let chunk = TranscriptPolisher.Chunk(
            ids: testCase.raw.map { _ in UUID() },
            lines: testCase.raw
        )
        return TranscriptPolisher.validate(
            reply: testCase.renderedReply,
            chunk: chunk,
            sanctioned: testCase.sanctioned
        )
    }

    // MARK: - The corpus itself

    @Test("Every corpus case lands on the side it was written for")
    func corpus_matchesEveryExpectation() throws {
        for testCase in try Self.loadCorpus() {
            let accepted = run(testCase) != nil
            #expect(
                accepted == testCase.mustAccept,
                "\(testCase.id) — expected \(testCase.expect), got \(accepted ? "accept" : "drop"). \(testCase.why)"
            )
        }
    }

    @Test("Russian passes at the same rate as English, and no trap gets through")
    func corpus_meetsTheCalibrationTarget() throws {
        let cases = try Self.loadCorpus()

        // Guard against the corpus being silently gutted — these numbers
        // are the floor the calibration was measured against.
        #expect(cases.count >= 40)
        #expect(cases.filter { $0.expect == "drop" }.count >= 20)

        let russian = cases.filter { $0.mustAccept && $0.lang == "ru" }
        #expect(russian.count >= 12)
        let russianPassed = russian.filter { run($0) != nil }.count
        let rate = Double(russianPassed) / Double(russian.count)
        #expect(
            rate >= 0.8,
            "Russian accept rate \(Int(rate * 100))% — the pass is a no-op on Russian again "
            + "(\(russianPassed)/\(russian.count)). Before the 2026-08-25 calibration it was 68%."
        )

        // The other half of the trade. A single leak here means a
        // loosened guard, not a better one.
        let leaked = cases.filter { !$0.mustAccept && run($0) != nil }
        #expect(leaked.isEmpty, "traps accepted: \(leaked.map(\.id).joined(separator: ", "))")
    }

    // MARK: - The pieces the calibration rests on

    @Test("Folding puts a brand's Cyrillic and Latin spellings in the same place")
    func fold_unifiesBrandScripts() {
        #expect(TranscriptPolisher.fold("фигма") == TranscriptPolisher.fold("figma"))
        // Inflected — the form Russian actually produces in a sentence.
        #expect(TranscriptPolisher.fold("фигме") == TranscriptPolisher.fold("figma"))
        #expect(TranscriptPolisher.fold("гитхаб") == TranscriptPolisher.fold("github"))
        #expect(TranscriptPolisher.fold("зуме") == TranscriptPolisher.fold("zoom"))
        // The curated table's own exclusions still hold: «зуммер» is a
        // buzzer, not Zoom, and must not fold onto it.
        #expect(TranscriptPolisher.fold("зуммер") != TranscriptPolisher.fold("zoom"))
    }

    @Test("Short Cyrillic words are not transliterated into their English lookalikes")
    func fold_leavesShortWordsAlone() {
        // «но» → "no" and «он» → "on" would forgive a real edit as if it
        // were a script change. The length floor is what stops that.
        #expect(TranscriptPolisher.fold("но") != TranscriptPolisher.fold("no"))
        #expect(TranscriptPolisher.fold("он") != TranscriptPolisher.fold("on"))
        // Long enough to carry signal — and this is the case that makes
        // name restoration free without any vocabulary at all.
        #expect(TranscriptPolisher.fold("прия") == TranscriptPolisher.fold("priya"))
    }

    @Test("A substitution is only forgiven when the original resembles it")
    func plausible_requiresResemblance() {
        #expect(TranscriptPolisher.plausible("алекс", "alex"))
        #expect(TranscriptPolisher.plausible("паракит", "parakeet"))
        #expect(TranscriptPolisher.plausible("висперкит", "whisperkit"))
        // The attack this exists for: "Alex" is a sanctioned name, but
        // putting it where the speaker said "he" invents an attribution.
        #expect(!TranscriptPolisher.plausible("he", "alex"))
        #expect(!TranscriptPolisher.plausible("надо", "priya"))
        // Two- and three-letter tokens are refused outright — one edit
        // reaches too much of the dictionary at that length.
        #expect(!TranscriptPolisher.plausible("на", "no"))
    }

    @Test("Restoring a known term is free; inventing a mention of one is not")
    func correctionCost_chargesInventedMentions() {
        let terms = TranscriptPolisher.SanctionedTerms(
            context: .init(attendees: ["Alex Novak"], vocabulary: ["Parakeet"], meetingApp: nil)
        )
        // Same words, one name written properly — the job.
        #expect(TranscriptPolisher.correctionCost(
            from: TranscriptPolisher.tokenize("алекс проверит бэкенд после обеда"),
            to: TranscriptPolisher.tokenize("Alex проверит бэкенд после обеда"),
            sanctioned: terms
        ) == 0)
        // Nothing was mangled here — the mention is new, and pure
        // insertion has no original to have replaced.
        #expect(TranscriptPolisher.correctionCost(
            from: TranscriptPolisher.tokenize("проверит бэкенд после обеда"),
            to: TranscriptPolisher.tokenize("Alex проверит бэкенд после обеда"),
            sanctioned: terms
        ) == 1)
        // Two tokens collapsing into one restored term.
        #expect(TranscriptPolisher.correctionCost(
            from: TranscriptPolisher.tokenize("виспер кит работает быстрее"),
            to: TranscriptPolisher.tokenize("WhisperKit работает быстрее"),
            sanctioned: TranscriptPolisher.SanctionedTerms(
                context: .init(attendees: [], vocabulary: ["WhisperKit"], meetingApp: nil)
            )
        ) == 0)
    }

    @Test("The sanctioned credit is capped so a rewrite can't buy its way through")
    func correctionCost_capsCredit() {
        let terms = TranscriptPolisher.SanctionedTerms(
            context: .init(attendees: ["Alex Novak"], vocabulary: [], meetingApp: nil)
        )
        // Four substitutions, each individually indistinguishable from
        // the correction we asked for. One in three is all a line gets:
        // the rest are charged, which is what stops a model from
        // replacing an utterance one sanctioned word at a time.
        let before = TranscriptPolisher.tokenize("алекс и алекс и алекс и алекс и потом решили это")
        let after = TranscriptPolisher.tokenize("Alex и Alex и Alex и Alex и потом решили это")
        #expect(before.count == 11)   // cap = 11 / 3 = 3 credits
        #expect(TranscriptPolisher.correctionCost(
            from: before, to: after, sanctioned: terms
        ) == 1)
    }

    @Test("An English word is not a free substitute for the brand it rhymes with")
    func correctionCost_refusesSameScriptSubstitution() {
        // Half the built-in brand table is an ordinary English word:
        // Steam, Intel, Booking, Notion, Word, Slack. Sanctioning them
        // unconditionally made "team" → "Steam" free — in the language
        // that never needed the credit, since case folding already makes
        // "figma" → "Figma" cost nothing.
        let before = TranscriptPolisher.tokenize("i was looking at the team dashboard")
        let after = TranscriptPolisher.tokenize("I was Booking at the Steam dashboard")
        #expect(TranscriptPolisher.correctionCost(from: before, to: after) == 2)
    }

    @Test("A credit has to come from where the correction landed")
    func correctionCost_requiresLocality() {
        // A word deleted at the start of the line must not pay for a
        // clause invented at the end, however alike the two happen to
        // look («black» is two edits from "Slack").
        let before = TranscriptPolisher.tokenize("the black box test failed so we escalated to Dmitry")
        let after = TranscriptPolisher.tokenize("The box test failed so we escalated to Dmitry on Slack")
        #expect(TranscriptPolisher.correctionCost(from: before, to: after) >= 2)
    }

    @Test("Swapping one known product for another is refused outright")
    func validate_rejectsKnownTermSwap() {
        // Two tokens in an eighteen-token chunk — below every ratio in
        // the file, and a change of fact rather than of spelling. Only a
        // structural rule catches it.
        let chunk = TranscriptPolisher.Chunk(
            ids: [UUID(), UUID()],
            lines: [
                "мы всё это держим в гитхабе а созвоны в зуме",
                "и дизайн лежит в фигме уже вторую неделю",
            ]
        )
        let reply = "1. Мы всё это держим в GitLab, а созвоны в Zoom.\n"
            + "2. И дизайн лежит в FigJam уже вторую неделю."
        #expect(TranscriptPolisher.validate(reply: reply, chunk: chunk) == nil)
    }

    @Test("Adding or dropping a negation is never a correction")
    func negationCount_isScriptAndContractionAware() {
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("мы не будем это делать")) == 1)
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("мы будем это делать")) == 0)
        // A contraction and its expansion must agree, or every model that
        // writes "do not" for "don't" would look like it inverted a
        // sentence.
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("we don't ship on friday"))
                == TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("we do not ship on Friday")))
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("we can't ship on friday"))
                == TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("we cannot ship on Friday")))
        // A possessive is not a contraction — "it's" must not read as a
        // negation just because it has an apostrophe in it.
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("it's fine")) == 0)
        // Neither is a hyphenated brand. «T-Bank» tokenizes to [t, bank],
        // and counting that bare "t" made Daisy's OWN normalization of it
        // look like a polarity flip.
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("мы обсудили T-Bank")) == 0)
        #expect(TranscriptPolisher.negationCount(TranscriptPolisher.tokenize("a T-shirt and a model T")) == 0)
    }

    @Test("A polished line that quietly drops a negation is refused")
    func validate_rejectsPolarityFlip() {
        let chunk = TranscriptPolisher.Chunk(
            ids: [UUID(), UUID()],
            lines: ["мы не будем это делать в этом квартале", "окей понял"]
        )
        let reply = "1. Мы будем это делать в этом квартале.\n2. Окей, понял."
        #expect(TranscriptPolisher.validate(reply: reply, chunk: chunk) == nil)
    }
}
