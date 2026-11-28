// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  TranscriptPolisherTests.swift
//  DaisyTests
//
//  The second transcript pass hands a language model the user's own
//  words and writes the reply back over them. Everything that stops
//  that from going wrong is pure, synchronous, and lives here: the
//  reply parser, the chunker, and the three guards (line count,
//  per-line length, token-diff budget).
//
//  These tests are written from the attacker's side — the interesting
//  cases are the replies a model plausibly produces when it has
//  decided to be helpful instead of literal.
//

import Testing
import Foundation
@testable import Daisy

@Suite("Transcript polish guards")
struct TranscriptPolisherTests {

    // MARK: - Helpers

    private func segment(_ text: String, at offset: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            text: text,
            isFinal: true
        )
    }

    private func chunk(_ lines: [String]) -> TranscriptPolisher.Chunk {
        TranscriptPolisher.Chunk(ids: lines.map { _ in UUID() }, lines: lines)
    }

    /// The reply shape the prompt asks for.
    private func reply(_ lines: [String]) -> String {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    // MARK: - Reply parsing

    @Test("Numbered lines parse with either separator")
    func parse_acceptsPeriodAndParenthesis() {
        let parsed = TranscriptPolisher.parseNumberedLines("1. первая\n2) вторая")
        #expect(parsed?[1] == "первая")
        #expect(parsed?[2] == "вторая")
    }

    @Test("A wrapped line folds back onto its number")
    func parse_foldsContinuationLines() {
        // A model that hard-wraps a long utterance must not read as a
        // missing line — that would fail the count guard and throw away
        // a chunk that was actually fine.
        let parsed = TranscriptPolisher.parseNumberedLines("1. начало строки\nи её продолжение\n2. вторая")
        #expect(parsed?[1] == "начало строки и её продолжение")
        #expect(parsed?[2] == "вторая")
        #expect(parsed?.count == 2)
    }

    @Test("Prose before the first number is ignored")
    func parse_ignoresPreamble() {
        let parsed = TranscriptPolisher.parseNumberedLines("Sure! Here are the corrected lines:\n1. привет")
        #expect(parsed?.count == 1)
        #expect(parsed?[1] == "привет")
    }

    @Test("A repeated number fails the parse rather than silently winning")
    func parse_rejectsDuplicateNumbers() {
        #expect(TranscriptPolisher.parseNumberedLines("1. первая\n1. другая\n2. вторая") == nil)
    }

    @Test("A reply with no numbering at all is a parse failure")
    func parse_rejectsUnnumbered() {
        #expect(TranscriptPolisher.parseNumberedLines("привет\nкак дела") == nil)
    }

    @Test("A line opening with a long figure isn't mistaken for a marker")
    func parse_ignoresOverlongLeadingDigits() {
        // "1234567." is a number in the text, not line 1234567.
        #expect(TranscriptPolisher.parseNumberedLines("1234567. рублей") == nil)
    }

    // MARK: - Chunking

    @Test("Segments under the budget travel together")
    func chunking_packsSmallSegments() {
        let segments = (0..<3).map { segment(String(repeating: "а", count: 700), at: Double($0)) }
        let chunks = TranscriptPolisher.makeChunks(segments)
        #expect(chunks.count == 1)
        #expect(chunks.first?.lines.count == 3)
    }

    @Test("A short tail is folded back rather than sent as its own request")
    func chunking_mergesTinyTrailingChunk() {
        // Every provider rejects a payload under 40 characters outright,
        // so a lone trailing "Ага." would burn a guaranteed failure.
        let segments = [
            segment(String(repeating: "а", count: 2_400), at: 0),
            segment(String(repeating: "б", count: 300), at: 1),
            segment("Ага.", at: 2),
        ]
        let chunks = TranscriptPolisher.makeChunks(segments)
        #expect(chunks.count == 2)
        #expect(chunks.last?.lines == [String(repeating: "б", count: 300), "Ага."])
    }

    @Test("A chunk stays under the providers' output-token ceiling")
    func chunking_budgetLeavesRoomForTheEchoedReply() {
        // The reply must echo every line back, and all five providers
        // cap output at 4096 tokens. Russian is ~1 token per character
        // worst case, so the character budget is the real guard against
        // a truncated — and therefore discarded — reply.
        #expect(TranscriptPolisher.chunkCharacterBudget <= 3_000)
    }

    @Test("The budget splits between segments, never inside one")
    func chunking_splitsOnSegmentBoundaries() {
        let segments = (0..<3).map { segment(String(repeating: "а", count: 2_500), at: Double($0)) }
        let chunks = TranscriptPolisher.makeChunks(segments)
        #expect(chunks.count == 3)
        // Whole segments only — a cut mid-sentence would strip the very
        // context that lets the model recognize a name.
        #expect(chunks.allSatisfy { $0.lines.count == 1 && $0.lines[0].count == 2_500 })
    }

    @Test("A single oversized utterance gets its own chunk rather than being cut")
    func chunking_keepsOversizedSegmentWhole() {
        let long = String(repeating: "б", count: TranscriptPolisher.chunkCharacterBudget * 2)
        let chunks = TranscriptPolisher.makeChunks([segment(long)])
        #expect(chunks.count == 1)
        #expect(chunks.first?.lines.first?.count == long.count)
    }

    @Test("Blank segments are never sent")
    func chunking_dropsEmptySegments() {
        let chunks = TranscriptPolisher.makeChunks([segment("   "), segment("привет"), segment("")])
        #expect(chunks.count == 1)
        #expect(chunks.first?.lines == ["привет"])
    }

    // MARK: - Validation: what gets through

    @Test("A brand correction is accepted and returned as a patch")
    func validate_acceptsBrandCorrection() {
        let c = chunk(["так вот фигма это наш основной инструмент дизайна сейчас"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["Так вот, Figma — это наш основной инструмент дизайна сейчас."]),
            chunk: c
        )
        #expect(accepted?.count == 1)
        #expect(accepted?[c.ids[0]] == "Так вот, Figma — это наш основной инструмент дизайна сейчас.")
    }

    @Test("A realistic Russian chunk survives every guard")
    func validate_acceptsRealisticMeetingChunk() {
        // The guards above are tight, and tight guards fail quietly: a
        // pass that rejects everything looks exactly like a pass that's
        // working. This is the counterweight — a whole chunk of Russian
        // meeting speech with four transliterated brands and names
        // restored and punctuation added throughout, which is precisely
        // what this feature exists to do and must therefore be accepted.
        let c = chunk([
            "так вот фигма это наш основной инструмент дизайна сейчас",
            "прия скинет макеты в четверг наверное",
            "да мы всё положили в гитхаб на прошлой неделе",
            "ну и там ещё зум записывал всю встречу",
            "окей тогда договорились до встречи",
            "эм ну да наверное так и сделаем",
        ])
        let accepted = TranscriptPolisher.validate(
            reply: reply([
                "Так вот, Figma — это наш основной инструмент дизайна сейчас.",
                "Priya скинет макеты в четверг, наверное.",
                "Да, мы всё положили в GitHub на прошлой неделе.",
                "Ну и там ещё Zoom записывал всю встречу.",
                "Окей, тогда договорились. До встречи.",
                "Эм, ну да, наверное, так и сделаем.",
            ]),
            chunk: c
        )
        #expect(accepted?.count == 6)
        #expect(accepted?[c.ids[0]]?.contains("Figma") == true)
        #expect(accepted?[c.ids[1]]?.contains("Priya") == true)
        #expect(accepted?[c.ids[2]]?.contains("GitHub") == true)
        #expect(accepted?[c.ids[3]]?.contains("Zoom") == true)
        // Filler stays: "эм", "ну", "наверное" are part of the record.
        #expect(accepted?[c.ids[5]]?.contains("Эм") == true)
        #expect(accepted?[c.ids[5]]?.contains("наверное") == true)
    }

    @Test("Punctuation and capitalization are free — they don't spend the diff budget")
    func validate_punctuationOnlyIsFree() {
        // Fixing punctuation is part of the remit, so it must not count
        // toward the budget that catches paraphrasing.
        let c = chunk(["привет как дела"])
        let accepted = TranscriptPolisher.validate(reply: reply(["Привет, как дела?"]), chunk: c)
        #expect(accepted?[c.ids[0]] == "Привет, как дела?")
    }

    @Test("Unchanged lines produce no patch entries")
    func validate_returnsOnlyChangedLines() {
        let c = chunk(["привет", "как дела у тебя сегодня вечером"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["привет", "как дела у тебя сегодня вечером"]),
            chunk: c
        )
        #expect(accepted?.isEmpty == true)
    }

    // MARK: - Validation: what gets rejected

    @Test("A paraphrase blows the token budget and drops the chunk")
    func validate_rejectsParaphrase() {
        // Same meaning, most of the words gone — exactly the failure this
        // pass must never ship, and exactly what a "helpful" model does.
        let c = chunk(["ну то есть мы вроде как договорились что сделаем это на следующей неделе"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["Мы договорились сделать это на следующей неделе."]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("An invented clause appended to a line is rejected")
    func validate_rejectsAppendedContent() {
        // The cheapest way to corrupt a transcript: leave every word
        // alone and add new ones. Costs nothing at all if the diff only
        // counts what disappeared, so this is the case that forced the
        // token diff to be symmetric and the length ceiling to be tight.
        let c = chunk(["ну и там по срокам мы вроде решили"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["Ну и там по срокам мы вроде решили — запуск двадцатого марта."]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("An appended translation is rejected")
    func validate_rejectsAppendedTranslation() {
        let c = chunk(["ну давайте тогда так и договоримся на этом"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["Ну давайте тогда так и договоримся на этом (let's agree on that)"]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("Assistant chatter after the last line doesn't become an utterance")
    func validate_rejectsTrailingChatter() {
        // The reply is well-formed right up to the sign-off, and the
        // sign-off looks exactly like a wrapped final line. Folding it in
        // would put the model's own words in a participant's mouth.
        let c = chunk([
            "первая строка нашего разговора про сроки проекта",
            "вторая строка нашего разговора про бюджет команды",
        ])
        let accepted = TranscriptPolisher.validate(
            reply: reply([
                "Первая строка нашего разговора про сроки проекта.",
                "Вторая строка нашего разговора про бюджет команды.",
            ]) + "\n\nLet me know if you need anything else.",
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("Two lines swapping text is caught by the per-line budget")
    func validate_rejectsSwappedLines() {
        // Cheap chunk-wide (two lines out of many) but catastrophic:
        // `applyCorrectedText` patches text by segment id and leaves
        // speakerId alone, so a swap leaves one speaker saying another's
        // words under their own timestamp.
        let a = "мы обсудили бюджет на следующий квартал и решили его увеличить"
        let b = "давайте вернёмся к этому вопросу на следующей встрече в понедельник"
        let c = chunk([a, b])
        #expect(TranscriptPolisher.validate(reply: reply([b, a]), chunk: c) == nil)
    }

    @Test("A wordless line may not gain words")
    func validate_rejectsWordsInWordlessLine() {
        // Whisper emits "...", "♪" and friends on silence and music.
        // With no tokens on the left there is nothing for the diff
        // budget to charge against, so the rule has to be structural.
        let c = chunk(["...", "вторая строка нашего разговора про бюджет"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["Мы согласовали бюджет.", "вторая строка нашего разговора про бюджет"]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("An empty chunk is dropped, not trapped on")
    func validate_handlesEmptyChunk() {
        #expect(TranscriptPolisher.validate(reply: "1. привет", chunk: chunk([])) == nil)
    }

    @Test("A condensed reply fails the line-count contract")
    func validate_rejectsMergedLines() {
        let c = chunk(["первая строка разговора здесь", "вторая строка разговора здесь"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["первая строка разговора здесь вторая строка разговора здесь"]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("An invented extra line fails the line-count contract")
    func validate_rejectsExtraLines() {
        let c = chunk(["первая строка разговора здесь"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["первая строка разговора здесь", "и ещё одна придуманная"]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("Renumbered output fails even when the count matches")
    func validate_rejectsWrongNumbering() {
        let c = chunk(["первая строка разговора здесь", "вторая строка разговора здесь"])
        let accepted = TranscriptPolisher.validate(
            reply: "2. первая строка разговора здесь\n3. вторая строка разговора здесь",
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("An emptied line is a deletion, not a correction")
    func validate_rejectsEmptiedLine() {
        let c = chunk(["эм ну да", "вторая строка разговора здесь"])
        let accepted = TranscriptPolisher.validate(
            reply: "1.\n2. вторая строка разговора здесь",
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("A line that ballooned is a rewrite, not a fix")
    func validate_rejectsExpandedLine() {
        let c = chunk(["ага"])
        let accepted = TranscriptPolisher.validate(
            reply: reply(["Да, я полностью согласен с этим предложением и поддерживаю его."]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("An unparseable reply drops the chunk")
    func validate_rejectsUnparseableReply() {
        let c = chunk(["привет"])
        #expect(TranscriptPolisher.validate(reply: "I'm sorry, I can't help with that.", chunk: c) == nil)
    }

    @Test("One bad line takes the whole chunk down with it")
    func validate_isAllOrNothingPerChunk() {
        // A reply that broke its contract on one line isn't trustworthy
        // on the others — salvaging the good-looking ones is how a
        // paraphrase slips through.
        let c = chunk([
            "так вот фигма это наш основной инструмент дизайна сейчас",
            "ну то есть мы вроде как договорились что сделаем это на следующей неделе",
        ])
        let accepted = TranscriptPolisher.validate(
            reply: reply([
                "Так вот, Figma — это наш основной инструмент дизайна сейчас.",
                "Мы договорились сделать это на следующей неделе.",
            ]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    // MARK: - Token diffing

    @Test("Substitutions, deletions and insertions all cost tokens")
    func tokenDiff_isSymmetric() {
        let before = TranscriptPolisher.tokenize("фигма и гитхаб")
        #expect(TranscriptPolisher.changedTokenCount(
            from: before,
            to: TranscriptPolisher.tokenize("Figma и гитхаб")
        ) == 1)
        // Insertions are NOT free — that's what makes "add an invented
        // clause and touch nothing else" expensive instead of costless.
        #expect(TranscriptPolisher.changedTokenCount(
            from: before,
            to: TranscriptPolisher.tokenize("фигма и гитхаб и ещё")
        ) == 2)
        #expect(TranscriptPolisher.changedTokenCount(
            from: before,
            to: TranscriptPolisher.tokenize("и гитхаб")
        ) == 1)
    }

    @Test("Unspaced scripts tokenize per character, not per clause")
    func tokenize_splitsUnspacedScripts() {
        // Whitespace-splitting Japanese yields one token per clause,
        // which makes rewriting a whole clause cost 1 — and makes an
        // honest one-character name fix cost the same. Per-character
        // granularity puts it back on a comparable footing.
        #expect(TranscriptPolisher.tokenize("今日は会議です")
                == ["今", "日", "は", "会", "議", "で", "す"])
        // A Latin brand inside CJK still compares as one token.
        #expect(TranscriptPolisher.tokenize("zoomで会議") == ["zoom", "で", "会", "議"])
        // Korean is spaced — it must NOT be split.
        #expect(TranscriptPolisher.tokenize("회의 일정") == ["회의", "일정"])
    }

    @Test("A rewritten Japanese clause costs its characters, not one token")
    func validate_rejectsRewrittenCJKClause() {
        let c = chunk([
            "今日は会議の予定について話しました",
            "来週の水曜日に集まることにしましょう",
            "資料は事前に共有しておきます",
        ])
        let accepted = TranscriptPolisher.validate(
            reply: reply([
                "今日は会議の予定について話しました",
                "来週の水曜日に集まることにしましょう",
                "予算はすべて承認されました",  // invented, same length
            ]),
            chunk: c
        )
        #expect(accepted == nil)
    }

    @Test("Repeated words are matched as a multiset, not a set")
    func tokenDiff_treatsRepeatsAsMultiset() {
        // "да да да" → "да" drops two tokens. A set comparison would
        // score this as unchanged and let a deletion through.
        #expect(TranscriptPolisher.changedTokenCount(
            from: TranscriptPolisher.tokenize("да да да"),
            to: TranscriptPolisher.tokenize("да")
        ) == 2)
    }

    @Test("Tokenizing folds case and drops punctuation")
    func tokenize_normalizes() {
        #expect(TranscriptPolisher.tokenize("Привет, как дела?") == ["привет", "как", "дела"])
        #expect(TranscriptPolisher.tokenize("GPT-5 и API") == ["gpt", "5", "и", "api"])
    }

    // MARK: - Payload shape

    @Test("The payload numbers from 1 and flattens embedded newlines")
    func payload_isOneLinePerUtterance() {
        let payload = SummaryPrompt.transcriptPolishPayload(lines: ["первая", "вторая\nс переносом"])
        #expect(payload == "1. первая\n2. вторая с переносом")
        // Round-trips through the parser it was designed for.
        let parsed = TranscriptPolisher.parseNumberedLines(payload)
        #expect(parsed?.count == 2)
        #expect(parsed?[2] == "вторая с переносом")
    }

    // MARK: - Prompt context

    @Test("Context sections are omitted when empty, not left blank")
    func prompt_omitsEmptyContextSections() {
        let bare = SummaryPrompt.transcriptPolishSystemInstructions(
            context: .init(attendees: [], vocabulary: [], meetingApp: nil)
        )
        #expect(!bare.contains("calendar invite"))
        #expect(!bare.contains("vocabulary"))

        let full = SummaryPrompt.transcriptPolishSystemInstructions(
            context: .init(attendees: ["Priya Raman"], vocabulary: ["Parakeet"], meetingApp: "Zoom")
        )
        #expect(full.contains("Priya Raman"))
        #expect(full.contains("Parakeet"))
        #expect(full.contains("Zoom"))
    }

    @Test("The freeform variant keeps every rule and drops only the JSON envelope")
    func prompt_freeformKeepsRules() {
        let context = TranscriptPolisher.PromptContext(attendees: ["Priya Raman"], vocabulary: [], meetingApp: nil)
        let json = SummaryPrompt.transcriptPolishSystemInstructions(context: context)
        let freeform = SummaryPrompt.transcriptPolishSystemInstructions(context: context, jsonEnvelope: false)
        #expect(json.contains("clientFollowUp"))
        #expect(!freeform.contains("clientFollowUp"))
        // The rules are the feature — they must not drift between providers.
        for rule in ["Never rephrase", "Never remove or add words", "LEAVE IT EXACTLY AS IT IS", "Priya Raman"] {
            #expect(json.contains(rule))
            #expect(freeform.contains(rule))
        }
    }
}
