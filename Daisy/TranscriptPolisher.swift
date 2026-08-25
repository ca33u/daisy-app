//
//  TranscriptPolisher.swift
//  Daisy
//
//  Second LLM pass over a FINISHED transcript — the text-layer
//  counterpart to the final Whisper pass (which is the ASR layer).
//  Whisper hears "фигма", "Прия", "эй-пи-ай"; a model that knows who
//  was on the invite and what's in the user's vocabulary writes
//  "Figma", "Priya", "API". Nothing else is allowed to change.
//
//  Runs on the user's OWN summary provider (Apple Intelligence /
//  Ollama / LM Studio locally, or their own API key), so "everything
//  stays on this Mac" survives the feature — the pass is only offered
//  when the transcript was already going to that provider anyway.
//
//  Three properties make this safe to run unattended:
//
//    1. **It never sees structure.** The model is handed numbered
//       utterance TEXT and nothing else — no `## Transcript` heading,
//       no `**[00:12 · Remote A]**` prefixes, no frontmatter. Speaker
//       labels and timings are re-rendered from the untouched segment
//       metadata afterwards, so there is no prompt in the world that
//       can corrupt them.
//    2. **Every chunk is checked before it is believed.** The reply
//       must return every line, same count, same numbers, with nothing
//       trailing it; each line must stay within a tight length band,
//       keep its negations, and change no more than half its own word
//       tokens; and the chunk as a whole gets a 15% token budget,
//       counting insertions as dearly as deletions. A chunk that fails
//       any of these is dropped whole and the original text stands. So:
//       paraphrase, condensation, invented clauses, swapped lines, and
//       the model's own sign-off all end the same way — with the
//       transcript unchanged.
//
//       What that budget MEASURES was recalibrated on 2026-08-25. The
//       thresholds are unchanged; the arithmetic under them stopped
//       charging Russian for corrections English got for free. See
//       `fold` for the asymmetry and `scripts/polish-corpus` for the
//       regression corpus that pins both halves of the trade.
//    3. **The raw transcript survives on disk** as `transcript.raw.md`,
//       so the polish is a re-creatable layer rather than a
//       destructive edit.
//
//  Degradation is silent by design: a provider timeout, a refusal, a
//  malformed reply, or a blown deadline all end with the un-polished
//  transcript and a line in os_log. The user is mid-close-the-laptop;
//  there is nothing here worth a toast.
//

import Foundation
import os

nonisolated enum TranscriptPolisher {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "TranscriptPolisher")

    // MARK: - Tunables

    /// Target size of one request, in characters of utterance text.
    /// Chunk boundaries always fall between segments.
    ///
    /// The binding constraint is the reply, not the prompt: this task
    /// asks the model to echo every line BACK, and every provider caps
    /// output at 4096 tokens (`AnthropicAPISummarizer`, `OpenAI…`,
    /// `Ollama…`, `LMStudio…`, `Kimi…` all agree on that number). A
    /// truncated reply loses lines, fails the count contract, and the
    /// chunk is dropped — so an over-large budget doesn't degrade the
    /// polish, it silently deletes it. Russian is the worst case at
    /// roughly a token per character; 2500 keeps even that comfortably
    /// under the ceiling with the line numbers and JSON envelope on top.
    static let chunkCharacterBudget = 2_500

    /// A trailing chunk shorter than this is folded back into the
    /// previous one. Every provider rejects a payload under 40
    /// characters with `transcriptTooShort`, so a lone short utterance
    /// at the end would burn a request to produce a guaranteed failure.
    static let minTrailingChunkCharacters = 60

    /// Per-chunk ceiling. Bounds a single hung request so one bad chunk
    /// can't eat the whole budget.
    static let chunkDeadlineSeconds: Double = 25

    /// Floor and ceiling for the whole-pass deadline the caller derives
    /// from how long the final Whisper pass took (see
    /// `RecordingSession.runTranscriptPolish`). Once the deadline
    /// elapses, remaining chunks are skipped and whatever was already
    /// polished is kept — every chunk is validated independently, so a
    /// partial pass is not a broken one.
    static let minTotalDeadlineSeconds: Double = 20
    static let maxTotalDeadlineSeconds: Double = 120

    /// Share of a chunk's word tokens the model may change before we
    /// stop believing it. Name and brand corrections are a small
    /// fraction of any real utterance; a chunk where one word in six
    /// moved is a model that started paraphrasing, and paraphrase is
    /// exactly what this pass must never ship. Learned from the
    /// Apple-Intelligence × TaskLocal bug, where a polish pass quietly
    /// replaced the user's dictation with an invented letter.
    ///
    /// Held at 0.15 through the 2026-08-25 Russian calibration. The
    /// ceiling was never the problem — what was counted underneath it
    /// was (`correctionCost`). Loosening it would have bought Russian
    /// chunks a pass by giving every language more room to paraphrase.
    static let maxChangedTokenRatio = 0.15

    /// Same idea, per line, for lines long enough for the ratio to mean
    /// something. The chunk-wide budget alone is too coarse to notice a
    /// single line being replaced wholesale — two utterances swapping
    /// text costs only a few percent of a whole chunk, and would leave
    /// one speaker saying another's words under their own timestamp.
    static let maxChangedTokenRatioPerLine = 0.5
    static let perLineRatioMinimumTokens = 4

    /// A Cyrillic token shorter than this is not transliterated for
    /// comparison. Three-letter words collide across languages far too
    /// easily («но» → "no", «он» → "on", «мы» → "my"), and forgiving one
    /// of those is forgiving a real edit. Long tokens — which is what
    /// names and product words are — carry enough signal to be safe.
    static let minimumTransliterationLength = 4

    /// Ceiling on how many substitutions one line may have forgiven as
    /// "a term we told the model to restore", as a fraction of the
    /// line's tokens. Without it, a model could replace an utterance
    /// with a soup of vocabulary words and pay nothing: each individual
    /// swap looks exactly like the correction we asked for. One in three
    /// is far above any honest line (real corrections are one or two
    /// words) and far below a rewrite.
    static let sanctionedCreditDivisor = 3

    /// Longest run of consecutive original tokens that may collapse into
    /// one restored term. Covers the real shape — «виспер кит» →
    /// "WhisperKit", «эй пи ай» → "API" — without letting a whole clause
    /// be swallowed by one word.
    static let maximumMergeWindow = 3

    /// Below this length, `plausible` refuses to pair two tokens at all.
    /// One edit on a three-letter word reaches half the dictionary, and
    /// pairing is what buys a substitution its discount.
    static let minimumPlausibleLength = 3

    /// How far from where a correction LANDED we will look for the
    /// mangled original it replaced, in tokens. Without a locality rule
    /// the search spans the whole line, and "delete a word at the start,
    /// invent a mention at the end" reads as a restoration: a model
    /// appending "on Slack" would be paid for by an unrelated deletion
    /// ten words earlier. Slack of a few tokens is needed because merges
    /// shift every later index by one.
    static let maximumCreditDistance = 4

    // MARK: - Prompt context

    /// What the model gets to know about the meeting besides the words.
    /// All plain `Sendable` scalars so it threads across the actor hops
    /// into the `nonisolated` providers — same contract as
    /// `SummaryPrompt.BriefPromptInfo`.
    struct PromptContext: Sendable {
        /// Display names from the calendar invite. The single highest-
        /// value signal: these are the proper nouns most likely to be
        /// mangled and the ones a user notices immediately.
        let attendees: [String]
        /// Terms from the user's dictation vocabulary — their jargon,
        /// product names, and internal acronyms.
        let vocabulary: [String]
        /// "Zoom", "Google Meet", … — weak context that helps the model
        /// read platform chatter ("you're on mute") as speech rather
        /// than something to fix.
        let meetingApp: String?

        var isEmpty: Bool {
            attendees.isEmpty && vocabulary.isEmpty && (meetingApp?.isEmpty ?? true)
        }
    }

    /// The words the model was ASKED to put in — attendee names, the
    /// user's vocabulary, and the built-in brand table — reduced to
    /// comparison keys.
    ///
    /// A change into one of these is the job, not a deviation, so it can
    /// be forgiven — but only when it replaces something that plausibly
    /// WAS it (see `plausible`), and only up to a per-line cap. Membership
    /// alone buys nothing: "invent a mention of Figma" and "write down
    /// Figma where the speaker clearly said it" differ precisely in
    /// whether there is a mangled original standing where the correction
    /// landed.
    struct SanctionedTerms: Sendable {
        let folds: Set<String>

        /// Brands only — what the pass knows without being told anything
        /// about the meeting. The default for `validate`.
        static let builtIn = SanctionedTerms(
            folds: Set(BrandCorrections.canonicalFolds.values)
        )

        init(folds: Set<String>) {
            self.folds = folds
        }

        init(context: PromptContext) {
            var folds = SanctionedTerms.builtIn.folds
            for phrase in context.attendees + context.vocabulary {
                for token in TranscriptPolisher.tokenize(phrase) {
                    folds.insert(TranscriptPolisher.fold(token))
                }
            }
            self.folds = folds
        }

        func contains(_ fold: String) -> Bool { folds.contains(fold) }
    }

    // MARK: - Result

    struct Outcome: Sendable {
        /// New text keyed by segment id. Only segments the pass actually
        /// changed appear — callers apply this as a patch.
        let replacements: [UUID: String]
        let chunksTotal: Int
        let chunksApplied: Int
        /// True when the total deadline cut the pass short.
        let timedOut: Bool

        static let empty = Outcome(replacements: [:], chunksTotal: 0, chunksApplied: 0, timedOut: false)
    }

    // MARK: - Entry point

    /// Polish `segments` and return the text replacements to apply.
    ///
    /// Pure in the sense that matters: it mutates nothing, writes
    /// nothing, and reads no shared state — the caller owns applying
    /// the patch and saving the raw copy. Never throws; every failure
    /// path returns fewer replacements.
    ///
    /// `segments` should be the FINAL-quality set (post final-Whisper,
    /// post-diarization). Empty and whitespace-only segments are
    /// skipped rather than sent — they carry no proper nouns and would
    /// only waste context.
    static func polish(
        segments: [TranscriptSegment],
        context: PromptContext,
        localeHint: String?,
        deadlineSeconds: Double,
        summarize: @escaping @Sendable (String, SummaryTask) async throws -> MeetingSummary
    ) async -> Outcome {
        let candidates = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { return .empty }

        let chunks = makeChunks(candidates)
        guard !chunks.isEmpty else { return .empty }

        // Built once: the attendee/vocabulary side is small, but the
        // brand table underneath it is a few thousand entries and this
        // runs per chunk.
        let sanctioned = SanctionedTerms(context: context)

        let budget = min(max(deadlineSeconds, minTotalDeadlineSeconds), maxTotalDeadlineSeconds)
        let start = Date()
        var replacements: [UUID: String] = [:]
        var applied = 0
        var timedOut = false

        for (index, chunk) in chunks.enumerated() {
            // The caller's own rotation guard runs after this returns,
            // but a provider that ignores cancellation would otherwise
            // keep shipping the OLD session's transcript while the user
            // is already recording the next meeting.
            if Task.isCancelled {
                log.info("Polish cancelled after \(index, privacy: .public)/\(chunks.count, privacy: .public) chunks")
                break
            }
            let spent = Date().timeIntervalSince(start)
            let left = budget - spent
            // Don't start a chunk we can't plausibly finish — a request
            // issued with 2 seconds left is a guaranteed discard that
            // still costs tokens.
            guard left > 5 else {
                timedOut = true
                log.warning("Polish deadline reached after \(index, privacy: .public)/\(chunks.count, privacy: .public) chunks — keeping the rest un-polished")
                break
            }

            let deadline = min(chunkDeadlineSeconds, left)
            guard let reply = await withDeadline(seconds: deadline, operation: {
                try await summarize(
                    SummaryPrompt.transcriptPolishPayload(lines: chunk.lines),
                    .transcriptPolish(context)
                ).clientFollowUp
            }) else {
                log.warning("Polish chunk \(index, privacy: .public) failed or timed out — chunk kept as-is")
                continue
            }

            guard let accepted = validate(reply: reply, chunk: chunk, sanctioned: sanctioned) else {
                continue
            }
            for (id, text) in accepted { replacements[id] = text }
            applied += 1
        }

        log.info("Polish: \(applied, privacy: .public)/\(chunks.count, privacy: .public) chunks applied, \(replacements.count, privacy: .public) segment(s) rewritten in \(Int(Date().timeIntervalSince(start)), privacy: .public)s")
        return Outcome(
            replacements: replacements,
            chunksTotal: chunks.count,
            chunksApplied: applied,
            timedOut: timedOut
        )
    }

    // MARK: - Chunking

    struct Chunk {
        /// Segment ids in the order they were numbered, 1-based in the
        /// prompt. `ids[0]` is line 1.
        let ids: [UUID]
        /// The exact text sent for each id, trimmed.
        let lines: [String]
    }

    /// Split segments into request-sized runs. Never splits a segment;
    /// an utterance longer than the budget gets a chunk to itself rather
    /// than being cut mid-sentence (cutting would strip the very context
    /// that lets the model recognize a name).
    static func makeChunks(_ segments: [TranscriptSegment]) -> [Chunk] {
        var chunks: [Chunk] = []
        var ids: [UUID] = []
        var lines: [String] = []
        var size = 0

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !ids.isEmpty && size + text.count > chunkCharacterBudget {
                chunks.append(Chunk(ids: ids, lines: lines))
                ids = []
                lines = []
                size = 0
            }
            ids.append(segment.id)
            lines.append(text)
            size += text.count
        }
        if !ids.isEmpty {
            chunks.append(Chunk(ids: ids, lines: lines))
        }

        // Fold a too-short tail back into its predecessor rather than
        // spending a request that every provider will refuse outright.
        if chunks.count >= 2,
           let tail = chunks.last,
           tail.lines.reduce(0, { $0 + $1.count }) < minTrailingChunkCharacters {
            let previous = chunks[chunks.count - 2]
            chunks.removeLast(2)
            chunks.append(Chunk(ids: previous.ids + tail.ids, lines: previous.lines + tail.lines))
        }
        return chunks
    }

    // MARK: - Validation

    /// Parse the model's reply and decide whether to believe it.
    /// Returns the accepted replacements (changed lines only), or `nil`
    /// to discard the whole chunk.
    ///
    /// All-or-nothing per chunk on purpose: the failure mode we're
    /// defending against — the model deciding to summarize or
    /// paraphrase — is a property of the whole reply, not of individual
    /// lines. Salvaging "the lines that happen to look fine" out of a
    /// reply that broke its contract is how a paraphrase slips through.
    static func validate(
        reply: String,
        chunk: Chunk,
        sanctioned: SanctionedTerms = .builtIn
    ) -> [UUID: String]? {
        // `1...0` would trap. `makeChunks` never produces an empty
        // chunk, but this is internal and directly unit-tested, so a
        // future caller should get a dropped chunk, not a crash.
        guard !chunk.lines.isEmpty else { return nil }
        guard let parsed = parseNumberedLines(reply) else {
            log.warning("Polish reply unparseable — chunk dropped")
            return nil
        }

        // Contract: exactly the lines we sent, no more, no fewer.
        // A dropped line means the model condensed; an extra means it
        // invented. Either way the 1:1 mapping we rely on is gone.
        guard parsed.count == chunk.lines.count,
              Set(parsed.keys) == Set(1...chunk.lines.count) else {
            log.warning("Polish reply had \(parsed.count, privacy: .public) lines for \(chunk.lines.count, privacy: .public) sent — chunk dropped")
            return nil
        }

        var changedTokens = 0
        var totalTokens = 0
        var result: [UUID: String] = [:]

        for (number, polished) in parsed.sorted(by: { $0.key < $1.key }) {
            let original = chunk.lines[number - 1]
            let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)

            // An emptied line is a deletion, not a correction.
            guard !trimmed.isEmpty else {
                log.warning("Polish emptied a line — chunk dropped")
                return nil
            }

            // Per-line ballpark check. Corrections are local edits:
            // restoring a Latin spelling or adding a comma moves a line
            // by a few characters, not by half its length. The ceiling
            // is deliberately close to the input — a generous one lets a
            // model append an invented clause to every line, which the
            // token budget below would then have to catch alone.
            //
            // Both bounds carry a flat slack term rather than being
            // pure ratios: the floor so a short line can lose length to
            // a legitimate fix ("эй-пи-ай" → "API"), the ceiling so it
            // can gain a comma and a capital. The ceiling's slack is the
            // tighter of the two on purpose — every character of it is
            // room for an invented clause.
            let inCount = original.count
            let outCount = trimmed.count
            guard outCount * 2 + 20 >= inCount,
                  outCount <= inCount * 5 / 4 + 12 else {
                log.warning("Polish line length out of range (\(inCount, privacy: .public) → \(outCount, privacy: .public)) — chunk dropped")
                return nil
            }

            let before = tokenize(original)
            let after = tokenize(trimmed)

            // A line with no word tokens is punctuation, music notation,
            // or Whisper's silence artefact ("...", "♪"). There is
            // nothing in it to correct, and with an empty `before` the
            // token budget below can't charge for anything the model
            // puts there — so it may only stay wordless.
            if before.isEmpty {
                guard after.isEmpty else {
                    log.warning("Polish put words into a wordless line — chunk dropped")
                    return nil
                }
            }

            // Polarity is structural, not statistical. A dropped «не» —
            // or an added "not" — inverts what a participant said while
            // moving exactly one token, which every ratio in this
            // function is by construction blind to. There is no polish
            // that legitimately adds or removes a negation, so a
            // mismatch is never a false alarm. (Contractions are counted
            // through their stray "t", so "don't" and "do not" agree.)
            //
            // Two honest limits. A dropped «не» is itself a common ASR
            // error, so this makes that one error permanently
            // uncorrectable — the trade is deliberate, because a polish
            // pass guessing at negation is far worse than one that never
            // touches it. And it does NOT make the pass safe against
            // single-token meaning changes in general: swap a number
            // inside a 400-token chunk and no budget here will notice.
            // That is what `transcript.raw.md` on disk is for — the
            // polish is a layer, and the unedited record survives
            // underneath it.
            guard negationCount(before) == negationCount(after) else {
                log.warning("Polish changed a line's polarity — chunk dropped")
                return nil
            }

            let diff = correctionDiff(from: before, to: after, sanctioned: sanctioned)

            // A name or a product the pass RECOGNIZED, standing in the
            // original and gone from the reply. Structural for the same
            // reason polarity is: «гитхабе» → "GitLab" and "Priya" →
            // "Alex" move one token each, which no ratio notices, and
            // both change what the record says happened rather than how
            // it is spelled.
            guard !diff.droppedSanctionedTerm else {
                log.warning("Polish dropped a known name or product from a line — chunk dropped")
                return nil
            }

            let lineChanged = diff.cost
            if before.count >= perLineRatioMinimumTokens {
                guard Double(lineChanged) <= maxChangedTokenRatioPerLine * Double(before.count) else {
                    log.warning("Polish rewrote a single line (\(lineChanged, privacy: .public)/\(before.count, privacy: .public) tokens) — chunk dropped")
                    return nil
                }
            }
            totalTokens += before.count
            changedTokens += lineChanged

            if trimmed != original {
                result[chunk.ids[number - 1]] = trimmed
            }
        }

        // Chunk-wide diff budget — the main guard.
        if totalTokens > 0 {
            let ratio = Double(changedTokens) / Double(totalTokens)
            guard ratio <= maxChangedTokenRatio else {
                log.warning("Polish changed \(Int(ratio * 100), privacy: .public)% of tokens (limit \(Int(maxChangedTokenRatio * 100), privacy: .public)%) — chunk dropped")
                return nil
            }
        }

        return result
    }

    /// Parse `1. text` / `1) text` numbered output into `[number: text]`.
    ///
    /// Leading prose before the first number is ignored — models like to
    /// open with "Sure, here are the corrected lines:". Unnumbered lines
    /// BETWEEN two numbers are folded onto the earlier one, which is what
    /// a hard-wrapped long utterance looks like.
    ///
    /// Unnumbered text AFTER the last number fails the parse. It has the
    /// same shape as a wrapped final line, but it is also the shape of
    /// "Let me know if you need anything else." and
    /// "Note: corrected Figma from фигма" — and appending those to the
    /// last utterance writes the model's own words into the record as
    /// something a participant said. The trade is deliberate and
    /// one-sided: rejecting a genuinely wrapped final line costs one
    /// chunk's polish, accepting chatter corrupts the transcript.
    ///
    /// A reply with no numbers at all is a parse failure.
    static func parseNumberedLines(_ reply: String) -> [Int: String]? {
        var result: [Int: String] = [:]
        var current: Int? = nil
        // Unnumbered lines seen since the last number. Committed only
        // once ANOTHER number proves they were an interior wrap.
        var pendingContinuation: [String] = []

        for rawLine in reply.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let (number, rest) = splitLeadingNumber(line) {
                if let current, !pendingContinuation.isEmpty {
                    result[current] = ([result[current] ?? ""] + pendingContinuation)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    pendingContinuation = []
                }
                // A repeated number means the reply lost its structure —
                // we'd silently keep the last copy otherwise.
                if result[number] != nil { return nil }
                result[number] = rest
                current = number
            } else if current != nil, !line.isEmpty {
                pendingContinuation.append(line)
            }
        }
        guard pendingContinuation.isEmpty else { return nil }
        return result.isEmpty ? nil : result
    }

    /// `"12. Привет"` → `(12, "Привет")`. Nil when the line doesn't open
    /// with `<digits><.|)>`. Bounded at 6 digits so a line that opens
    /// with a year or a long figure isn't mistaken for a marker.
    private static func splitLeadingNumber(_ line: String) -> (Int, String)? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, digits.count < 6 {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex,
              line[index] == "." || line[index] == ")",
              let number = Int(digits) else { return nil }
        let rest = line[line.index(after: index)...]
        return (number, String(rest).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Token diffing

    /// Word tokens for the diff budget: letters and digits only,
    /// case-folded. Punctuation is deliberately dropped — fixing
    /// punctuation is part of this pass's remit, so it must not spend
    /// the change budget. Case is folded because "figma" → "Figma"
    /// should be free while "фигма" → "Figma" (a real token change) is
    /// what the budget is counting.
    ///
    /// Scripts that don't put spaces between words (Chinese, Japanese,
    /// Thai, Khmer, Lao, Burmese) are split per character instead.
    /// Whitespace-splitting them yields one "token" per clause, which
    /// breaks the budget in both directions at once: a wholesale rewrite
    /// of a clause costs 1, while an honest one-character name fix also
    /// costs 1 out of very few. Per-character granularity puts those
    /// languages on roughly the same footing as a spaced one.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .flatMap(splitRun)
    }

    /// One whitespace-delimited run → tokens. Characters from unspaced
    /// scripts each become their own token; anything else accumulates
    /// into a word, so a Latin brand embedded in Japanese ("zoomで会議")
    /// still compares as one token rather than four letters.
    private static func splitRun(_ run: Substring) -> [String] {
        guard run.contains(where: isUnspacedScript) else { return [String(run)] }
        var tokens: [String] = []
        var word = ""
        for character in run {
            if isUnspacedScript(character) {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(character))
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    /// True for characters from writing systems with no word separator.
    /// Hangul is intentionally absent — Korean puts spaces between
    /// words, so it tokenizes correctly as-is.
    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x0E00...0x0EFF,      // Thai, Lao
             0x1000...0x109F,      // Myanmar
             0x1780...0x17FF,      // Khmer
             0x3040...0x30FF,      // Hiragana, Katakana
             0x3400...0x4DBF,      // CJK Unified Ideographs Ext A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xF900...0xFAFF:      // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    // MARK: - Folding

    /// Comparison key for one token: what it is, ignoring the script it
    /// was written in.
    ///
    /// The problem this solves, in one line: restoring a brand costs
    /// NOTHING in English and a whole token in Russian. "figma" → "Figma"
    /// is free because `tokenize` folds case; «фигма» → "Figma" is a
    /// completely different string. Every Russian chunk therefore spent
    /// budget on exactly the corrections this pass exists to make, and a
    /// standup with four brands in it blew a 15% ceiling that an
    /// identical English standup never came near. Measured on the
    /// regression corpus (`scripts/polish-corpus`): Russian chunks
    /// passed 68% of the time, English 100%.
    ///
    /// Two steps, most specific first:
    ///  1. The curated brand table, which knows «фигму» (inflected!),
    ///     «гитхаб» and «зуме» are Figma, GitHub and Zoom. Curation is
    ///     the point — generic transliteration gets «джира» → "dzhira".
    ///  2. Plain transliteration for longer Cyrillic tokens, which
    ///     catches the names no table can hold («прия» → "priya").
    ///
    /// Applied to BOTH sides, so an untouched word still matches itself.
    /// A false match here forgives a change we might not have wanted; the
    /// length floor in step 2 is what keeps that from happening to short
    /// function words.
    static func fold(_ token: String) -> String {
        if let brand = BrandCorrections.canonicalFolds[token] { return brand }
        if token.count >= minimumTransliterationLength, isCyrillic(token) {
            return transliterate(token)
        }
        return token
    }

    private static func isCyrillic(_ token: String) -> Bool {
        var sawLetter = false
        for character in token where character.isLetter {
            sawLetter = true
            guard let scalar = character.unicodeScalars.first?.value,
                  (0x0400...0x04FF).contains(scalar) else { return false }
        }
        return sawLetter
    }

    /// Practical Cyrillic → Latin, tuned for MATCHING rather than for
    /// reading: the goal is that a Russian rendering and its English
    /// original land close enough for `plausible` to pair them, not that
    /// the output is a correct romanization of anything.
    private static let transliterationTable: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    private static func transliterate(_ token: String) -> String {
        var result = ""
        for character in token {
            result += transliterationTable[character] ?? String(character)
        }
        return result
    }

    // MARK: - Plausible substitutions

    /// Could `source` be what the engine heard where the speaker actually
    /// said `target`?
    ///
    /// This is the gate on the sanctioned-term credit, and the whole
    /// reason the credit is safe. "Alex" is a name we told the model
    /// about, so writing it is sanctioned — but only over «алекс», not
    /// over "he". Without this test, "and then HE said" politely becomes
    /// "and then ALEX said" for free, which is the single worst thing a
    /// transcript can do: attribute words to a named person who never
    /// said them.
    ///
    /// Edit distance on the transliterated forms, with the tolerance
    /// scaled to length. Short tokens are refused outright — at two or
    /// three characters, one edit reaches half the dictionary.
    static func plausible(_ source: String, _ target: String) -> Bool {
        // Transliterate unconditionally, per character: `source` can be
        // a RUN of tokens joined together («виспер» + «кит»), and a run
        // is routinely half-Latin already — the short-token floor in
        // `fold` leaves «кит» alone but «виспер» comes back as "visper".
        // Requiring the whole string to be Cyrillic would refuse exactly
        // the merges this function exists to approve. Non-Cyrillic
        // characters pass through untouched.
        let a = transliterate(source)
        let b = transliterate(target)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard min(a.count, b.count) >= minimumPlausibleLength else { return false }
        // 40% of the longer form. Transliteration is approximate by
        // nature — «алекс» comes back as "aleks", two edits from "Alex"
        // on a five-letter word — so a third is too tight to pair the
        // very cases this is for. It stays a narrow window in absolute
        // terms (two edits at five characters, four at ten), and a wrong
        // pairing costs one token of budget, never a chunk: the token
        // still has to BE a term the model was told about, the credit is
        // capped per line, and both ratio guards run afterwards.
        let tolerance = max(1, 2 * max(a.count, b.count) / 5)
        guard abs(a.count - b.count) <= tolerance else { return false }
        return editDistance(a, b) <= tolerance
    }

    /// Levenshtein, two rows. Inputs are single tokens (or a short run of
    /// them), so the quadratic shape is not worth optimizing away.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    // MARK: - Correction cost

    /// What `validate` needs to know about one line.
    struct CorrectionDiff {
        /// Tokens changed, after the discount.
        let cost: Int
        /// A term the pass KNOWS — a brand, an attendee, a vocabulary
        /// word — that stood in the original and is simply gone, with
        /// nothing plausible put in its place.
        ///
        /// Structural, like polarity, and for the same reason: swapping
        /// «гитхабе» for "GitLab" or "Priya" for "Alex" moves one token,
        /// which no ratio can see, and is a change of FACT rather than of
        /// spelling. A genuine restoration always leaves the term
        /// present — «фигме» → "Figma" keeps Figma — and a merge that
        /// consumed one («виспер кит» → "WhisperKit") has already been
        /// credited by the time this is computed.
        let droppedSanctionedTerm: Bool
    }

    /// Just the number, for callers that don't care why.
    static func correctionCost(
        from before: [String],
        to after: [String],
        sanctioned: SanctionedTerms = .builtIn
    ) -> Int {
        correctionDiff(from: before, to: after, sanctioned: sanctioned).cost
    }

    /// The diff budget's real measure: how much of this line the model
    /// changed, AFTER discounting the changes it was asked to make.
    ///
    /// Three things happen, in order:
    ///  1. Both sides are folded (`fold`), so a brand or a name restored
    ///     across scripts compares equal and costs nothing at all. This
    ///     alone is most of the Russian fix.
    ///  2. What is left is diffed as multisets, exactly as before —
    ///     insertions still cost as much as deletions.
    ///  3. A leftover NEW token that is a sanctioned term (attendee,
    ///     vocabulary, brand) is forgiven if a nearby run of leftover
    ///     ORIGINAL tokens plausibly WAS it (`mergeWindow`). That covers
    ///     what folding can't: «алекс» → "Alex" (transliteration lands a
    ///     letter off) and «виспер кит» → "WhisperKit" (two tokens
    ///     becoming one).
    ///
    /// The credit is capped per line, so a wholesale rewrite cannot buy
    /// itself through one sanctioned word at a time.
    static func correctionDiff(
        from before: [String],
        to after: [String],
        sanctioned: SanctionedTerms = .builtIn
    ) -> CorrectionDiff {
        let foldedBefore = before.map(fold)
        let foldedAfter = after.map(fold)
        // Positions, not tokens: deciding whether a substitution is
        // credible needs the ORIGINAL spelling (folding has already
        // turned «алекс» into Latin "aleks") and where in the line each
        // side sat.
        var lost = unmatchedPositions(of: foldedBefore, against: foldedAfter)
        let gained = unmatchedPositions(of: foldedAfter, against: foldedBefore)

        let raw = max(lost.count, gained.count)
        let cap = max(1, before.count / sanctionedCreditDivisor)

        // Nothing below can lower the cost by more than `cap`, so when
        // even a full refund leaves the line over its own ceiling the
        // answer is already known. Skipping the search here is what
        // keeps a wholesale rewrite of a 350-token utterance from
        // running a quadratic window scan on the main actor to produce a
        // verdict it was always going to reach.
        if before.count >= perLineRatioMinimumTokens,
           Double(raw - cap) > maxChangedTokenRatioPerLine * Double(before.count) {
            return CorrectionDiff(cost: raw, droppedSanctionedTerm: false)
        }

        var credits = 0
        for gainedIndex in gained {
            // Stop scanning the moment the line's allowance is spent.
            if credits >= cap { break }
            let term = foldedAfter[gainedIndex]
            guard sanctioned.contains(term),
                  let window = mergeWindow(
                      in: lost,
                      near: gainedIndex,
                      restoring: term,
                      originals: before,
                      folded: foldedBefore,
                      sanctioned: sanctioned
                  )
            else { continue }
            lost.removeSubrange(window)
            credits += 1
        }

        // Anything still on the lost side that we RECOGNIZED is a term
        // the model deleted or replaced with something else entirely.
        let droppedKnown = lost.contains { sanctioned.contains(foldedBefore[$0]) }

        return CorrectionDiff(
            cost: max(lost.count, gained.count - credits),
            droppedSanctionedTerm: droppedKnown
        )
    }

    /// The run of original tokens that `term` plausibly replaced, as a
    /// range into `lost`. Nil when nothing on the original side
    /// qualifies — the "the model invented this mention" case, which
    /// stays fully charged.
    ///
    /// Four conditions, and each one is a hole that was open without it:
    ///
    ///  • **Adjacent in the original line, and near where the correction
    ///    landed.** Otherwise a deletion at the start of a sentence pays
    ///    for an invented clause at the end — "The black box test failed"
    ///    → "The box test failed … on Slack" for free.
    ///  • **Cross-script, or a genuine multi-token merge.** This credit
    ///    exists to make a Latin name recoverable from a Cyrillic
    ///    rendering. English never needed it — "figma" → "Figma" is
    ///    already free under case folding — but granting it anyway made
    ///    every brand in the table a free substitute for its nearest
    ///    English word: team → Steam, until → Intel, looking → Booking,
    ///    cloud → Claude. The exception is a run of tokens that
    ///    transliterates EXACTLY onto the term, which is the real shape
    ///    of "whisper kit" → "WhisperKit".
    ///  • **The original is not itself a term we know.** Both sides being
    ///    sanctioned means the model swapped one known thing for another
    ///    — «гитхабе» → "GitLab" — and that is a factual change, not a
    ///    spelling one.
    ///
    /// LONGEST run first: «виспер»+«кит» transliterates to exactly
    /// "whisperkit", while «виспер» alone is merely close enough to pass,
    /// and taking the shorter match would credit the substitution and
    /// then charge for the leftover half of the same word.
    private static func mergeWindow(
        in lost: [Int],
        near gainedIndex: Int,
        restoring term: String,
        originals: [String],
        folded: [String],
        sanctioned: SanctionedTerms
    ) -> Range<Int>? {
        guard !lost.isEmpty else { return nil }
        let termKey = transliterate(term)
        for length in stride(from: min(maximumMergeWindow, lost.count), through: 1, by: -1) {
            for start in 0...(lost.count - length) {
                let positions = Array(lost[start..<(start + length)])
                guard let first = positions.first else { continue }
                guard isRun(positions) else { continue }
                guard abs(first - gainedIndex) <= maximumCreditDistance else { continue }

                let originalRun = positions.map { originals[$0] }.joined()
                let foldedRun = positions.map { folded[$0] }.joined()

                if sanctioned.contains(foldedRun), foldedRun != term { continue }

                let crossScript = containsCyrillic(originalRun)
                let exactMerge = length > 1 && transliterate(foldedRun) == termKey
                guard crossScript || exactMerge else { continue }

                if plausible(foldedRun, term) { return start..<(start + length) }
            }
        }
        return nil
    }

    /// True when the positions are consecutive in the original line. A
    /// window has to be a contiguous piece of what was said — joining
    /// two words with a surviving word between them is not a merge, it
    /// is two separate deletions being billed as one.
    private static func isRun(_ positions: [Int]) -> Bool {
        guard positions.count > 1 else { return true }
        for index in 1..<positions.count where positions[index] != positions[index - 1] + 1 {
            return false
        }
        return true
    }

    private static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    // MARK: - Polarity

    /// Words whose presence flips the meaning of a sentence.
    private static let negations: Set<String> = [
        "не", "нет", "ни", "никогда", "нельзя", "никак", "без",
        "not", "no", "never", "none", "nor", "without", "cannot",
    ]

    /// Words that leave a stray `"t"` behind when `tokenize` strips the
    /// apostrophe out of a contraction. `"don't"` becomes `["don", "t"]`,
    /// and counting that `"t"` is what keeps a contraction equal to its
    /// expansion — so a model writing "do not" for "don't" isn't accused
    /// of inverting a sentence.
    ///
    /// The preceding word has to be one of THESE, not any word at all: a
    /// bare `"t"` also falls out of "T-Bank", "T-shirt" and "model T",
    /// and counting those made Daisy's own «Т-Банк» normalization look
    /// like a polarity flip and drop the chunk.
    private static let contractionStems: Set<String> = [
        "don", "doesn", "didn", "won", "can", "couldn", "shouldn", "wouldn",
        "isn", "aren", "wasn", "weren", "hasn", "haven", "hadn", "ain",
        "mustn", "needn", "shan",
    ]

    static func negationCount(_ tokens: [String]) -> Int {
        var count = 0
        for (index, token) in tokens.enumerated() {
            if negations.contains(token) {
                count += 1
            } else if token == "t", index > 0, contractionStems.contains(tokens[index - 1]) {
                count += 1
            }
        }
        return count
    }

    /// Distance between two token multisets, in tokens. Comparing as
    /// multisets means a repeated word isn't matched twice; taking the
    /// larger of the two directions means an INSERTION costs as much as
    /// a deletion.
    ///
    /// The raw measure, kept as-is: `correctionCost` is what `validate`
    /// spends its budget on, and this is what that one is built from
    /// before any discount is applied.
    ///
    /// That symmetry is the point. Counting only what disappeared makes
    /// pure additions free, and "leave every word alone but append an
    /// invented clause" is both the cheapest way to corrupt a transcript
    /// and a completely natural thing for a helpful model to do —
    /// finishing a trailing-off sentence, appending a translation,
    /// tacking a note onto the end.
    static func changedTokenCount(from before: [String], to after: [String]) -> Int {
        max(unmatchedCount(of: before, against: after),
            unmatchedCount(of: after, against: before))
    }

    /// How many of `tokens` have no partner left in `pool`.
    private static func unmatchedCount(of tokens: [String], against pool: [String]) -> Int {
        unmatchedPositions(of: tokens, against: pool).count
    }

    /// WHERE in `tokens` the unpartnered ones sit, ascending.
    /// `correctionCost` needs positions, not just a count: whether a
    /// substitution is credible depends on the original spelling and on
    /// how far the replacement landed from it.
    private static func unmatchedPositions(of tokens: [String], against pool: [String]) -> [Int] {
        var available: [String: Int] = [:]
        for token in pool { available[token, default: 0] += 1 }
        var missing: [Int] = []
        for (index, token) in tokens.enumerated() {
            if let count = available[token], count > 0 {
                available[token] = count - 1
            } else {
                missing.append(index)
            }
        }
        return missing
    }

    // MARK: - Deadline

    /// Race `operation` against a sleep. Returns nil when the operation
    /// throws or the deadline wins. Same shape as
    /// `RecordingSession.polishWithDeadline`, minus that one's
    /// dictation-specific length gate — validation here is per chunk.
    ///
    /// Shared by the post-stop LLM passes: `SpeakerNameSuggester` races
    /// its single request the same way, and a second copy of this would
    /// be a second place for the cancellation semantics to drift.
    static func withDeadline(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> String
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil  // deadline sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
