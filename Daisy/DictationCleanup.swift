//
//  DictationCleanup.swift
//  Daisy
//
//  «Fix dictation by context» (28.11.2026): between recognition and
//  insertion a dictation's text may go once through the summary provider,
//  which replaces the words the recognizer misheard for the context and
//  fixes grammar, punctuation and false starts. It does not rewrite: the
//  meaning, the wording and the length stay, and nothing is added. This is
//  not the «in my voice» rewrite that left dictation on 2026-09-12
//  (`SummaryTask.dictationPolish`, still the selection rewrite's).
//
//  Off by default. Audio never leaves the Mac. With a provider that isn't
//  on this Mac the text does, and up to forty words of the person's
//  vocabulary with it, and then only after a yes given for that provider
//  and the place it sends text to (`DictationCleanupConsent`).
//
//  A dictation is never lost to it and never waits on it for long: the
//  answer has 2.5 s, and one that is late, failed, cut off, refused or
//  isn't the same text corrected is dropped — the text is inserted as it
//  was recognized. Everything here is the deciding, kept apart from the
//  app so it can be tested: `DictationPaste.handle` does the asking.
//
//  Nothing here logs a word of what was said: the log line carries the
//  provider's kind, the time, the two lengths and the outcome.
//

import Foundation
import Observation
import os

nonisolated enum DictationCleanup {
    /// How long the answer may take. Past it the text goes in as
    /// recognized: a person who has finished speaking is looking at an
    /// empty field.
    static let deadline: Duration = .milliseconds(2500)
    /// Shorter than this there is no context to correct by («да», «ок,
    /// спасибо»), and the round trip costs more than it can fix.
    static let minChars = 20
    /// The providers that answer in the JSON envelope keep their summary
    /// floor (a text has to be longer than 40 characters), so a dictation
    /// under 41 isn't sent to them.
    static let envelopeMinChars = 41
    /// Longer than this (in UTF-16 units, as Daisy's server counts its own
    /// 4,000) the answer can't be written inside the deadline. To be tuned
    /// by the bench (`DictationCleanupBench`).
    static let maxChars = 1200

    /// Settings → Dictation → «Fix dictation by context». Read straight
    /// from defaults by `DictationPaste`, which holds no `AppSettings`.
    static let enabledKey = "daisy.dictationCleanup.enabled"

    // MARK: - Whether to ask

    /// The provider that would be asked and where it sends text
    /// (`Summarizer.dictationCleanupRoute`), as they were when the yes was
    /// checked.
    nonisolated struct Route: Equatable, Sendable {
        let kind: SummaryProviderKind
        let destination: String
    }

    /// Why a dictation wasn't corrected, when that is neither a failure
    /// nor an answer that wasn't believed.
    nonisolated enum SkipReason: String, Sendable {
        /// The switch is off.
        case off
        /// The provider can't do it: a CLI started per request, or the
        /// local model, takes longer than a dictation can wait.
        case provider
        /// The Daisy Subscription is the provider and isn't there: signed
        /// out, or no active subscription (known from the last status, or
        /// said by the server).
        case noSubscription
        /// The provider isn't on this Mac and has no yes.
        case consent
        /// The provider is known not to be set up (no key, not installed).
        case notReady
        /// The subscription's allowance for the day, or the month, is used.
        case dailyLimit
        case monthlyLimit
        /// The provider failed three times running; it is left alone for
        /// a while (`Breaker`).
        case paused
        /// The caret is in a password field.
        case secureField
        case short
        case long
        /// Apple's on-device model doesn't write the dictation's language,
        /// or the language couldn't be told.
        case language
    }

    nonisolated enum Gate: Equatable, Sendable {
        case run
        case skip(SkipReason)
    }

    /// The switch, the provider and the yes, in that order. `kind` nil:
    /// the chosen provider can't clean a dictation
    /// (`Summarizer.dictationCleanupProviderKind`). `allowed` is the yes
    /// stored for this provider and where it sends text now; a provider
    /// that keeps the text on this Mac needs none.
    static func gate(enabled: Bool, kind: SummaryProviderKind?, isLocal: Bool, allowed: Bool) -> Gate {
        guard enabled else { return .skip(.off) }
        guard kind != nil else { return .skip(.provider) }
        guard isLocal || allowed else { return .skip(.consent) }
        return .run
    }

    /// The subscription's allowance that ran out.
    nonisolated enum Limit: String, Sendable {
        case daily, monthly
    }

    /// Everything that decides whether dictations are sent at all, apart
    /// from the dictation itself: the switch, the provider, the yes, and
    /// what is known of the provider's state. Plain values, so the gate
    /// and the caption in Settings read the same answer from the same
    /// facts (`standingSkip`, `DictationCleanupCaption`).
    nonisolated struct Standing: Equatable, Sendable {
        var enabled = false
        var route: Route?
        /// By the endpoint as it is configured, never by the provider's name.
        var isLocal = false
        var allowed = false
        /// Only for the Daisy Subscription: signed in, confirmed, and the
        /// last status read says active. nil for every other provider.
        var subscriptionActive: Bool?
        /// The provider is known not to be set up.
        var providerMissing = false
        /// An allowance that ran out a moment ago and is not asked about
        /// again yet (`DictationCleanupStatus`).
        var limit: Limit?
        /// The breaker is open for this provider.
        var paused = false
    }

    /// Why nothing is sent with things as they stand, or nil. The order is
    /// the order a person would fix them in: a subscription comes before
    /// its yes, the yes before the provider's own trouble.
    static func standingSkip(_ standing: Standing) -> SkipReason? {
        guard standing.enabled else { return .off }
        guard let route = standing.route else { return .provider }
        if standing.subscriptionActive == false { return .noSubscription }
        if case .skip(let reason) = gate(enabled: true, kind: route.kind, isLocal: standing.isLocal, allowed: standing.allowed) {
            return reason
        }
        if standing.providerMissing { return .notReady }
        if let limit = standing.limit { return limit == .daily ? .dailyLimit : .monthlyLimit }
        if standing.paused { return .paused }
        return nil
    }

    /// Whose yes a request goes by. Sendable by hand: `UserDefaults` is
    /// safe to use from any thread and only isn't marked so.
    nonisolated enum Permission: @unchecked Sendable {
        /// The switch and the yes stored in these defaults: the app's way.
        case stored(UserDefaults)
        /// Given for this run by whoever started it (the bench's
        /// `--allow-cloud`); the stored yes is neither read nor written.
        case granted
    }

    /// The request may not go: the provider, its address, the switch or
    /// the yes is no longer what the dictation was checked against.
    nonisolated struct NotPermitted: Error, Equatable {
        let reason: SkipReason
    }

    /// The last check before a request is built, made in the same turn of
    /// the main actor as the building (`Summarizer.cleanDictation`). The
    /// dictation was checked a moment earlier, and in between its language
    /// was detected off the main actor: the person may meanwhile have
    /// chosen another provider, pointed this one elsewhere, taken the yes
    /// back or switched the whole thing off. Then nothing is sent.
    static func permit(route: Route, current: Route?, isLocal: Bool, permission: Permission) throws {
        guard current == route else { throw NotPermitted(reason: current == nil ? .provider : .consent) }
        guard case .stored(let defaults) = permission else { return }
        let allowed = DictationCleanupConsent(defaults: defaults).isAllowed(route.kind, destination: route.destination)
        if case .skip(let reason) = gate(enabled: defaults.bool(forKey: enabledKey), kind: route.kind,
                                         isLocal: isLocal, allowed: allowed) {
            throw NotPermitted(reason: reason)
        }
    }

    /// The providers that read the answer as plain text; the rest get the
    /// JSON envelope every text-shaped task gets.
    static func repliesInPlainText(_ kind: SummaryProviderKind) -> Bool {
        switch kind {
        case .daisySubscription, .anthropic, .appleIntelligence: true
        default: false
        }
    }

    /// Too short to have a context, or too long to come back in time.
    static func lengthSkip(_ text: String, kind: SummaryProviderKind) -> SkipReason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < (repliesInPlainText(kind) ? minChars : envelopeMinChars) { return .short }
        if trimmed.utf16.count > maxChars { return .long }
        return nil
    }

    /// The answer's ceiling: about what was read, since nothing is added
    /// and there is no thinking. 2,048 is also the server's own cap for
    /// the task (src/complete.ts in daisy-api).
    static func maxTokens(userChars: Int) -> Int {
        min(2_048, 64 + userChars)
    }

    // MARK: - Whether to believe the answer

    /// Why an answer that did come wasn't used.
    nonisolated enum Rejection: String, Sendable {
        /// Not the same text corrected (`validate`).
        case reply
        /// Cut at the token ceiling: half a sentence.
        case truncated
        /// The model declined.
        case refused
        /// Ended for some other reason than being finished.
        case stopped
    }

    /// A reply that didn't end because the model had finished, for a
    /// reason with no error of its own.
    nonisolated struct UnfinishedReply: Error, Equatable {
        let stopReason: String
    }

    /// Anthropic's `stop_reason`, for the two providers that read its
    /// stream: only `end_turn` is a whole answer. `max_tokens` and
    /// `refusal` arrive as HTTP 200 with text in them, so they are refused
    /// here by name; no stop reason at all is a stream that broke off.
    static func requireFinished(stopReason: String?, provider: String) throws {
        switch stopReason {
        case "end_turn": return
        case "max_tokens": throw SummaryProviderError.outputTruncated(provider: provider)
        case "refusal": throw SummaryProviderError.refused(provider: provider)
        case let other?: throw UnfinishedReply(stopReason: other)
        case nil:
            throw SummaryProviderError.streamInterrupted(provider: provider,
                                                         message: String(localized: "The answer was cut off"))
        }
    }

    /// The shortest and the longest a believed answer may be against what
    /// was sent. Fillers and false starts taken out leave under half of a
    /// rambling sentence, so the floor is low — it is `sameText` that says
    /// whether what is left is the person's own; the ceiling stays tight,
    /// because a correction adds punctuation and little else.
    static let minShare = 0.3
    static let maxShare = 1.3

    /// The reply as the text to insert, or nil when it isn't the same text
    /// corrected. This string is about to be typed into someone's field in
    /// place of what they said, so everything that isn't plainly their own
    /// words put right is refused:
    ///  - nothing but thinking, or nothing at all;
    ///  - most of it gone, or a third longer;
    ///  - the prompt's own fence, or a privacy placeholder left in it;
    ///  - other words than theirs (`sameText`): an answer to what they
    ///    said, a translation, a refusal, a line before or after the text.
    /// Quotes or a code fence the model wrapped the text in are taken off
    /// first, when the text itself has none.
    static func validate(_ reply: String, input: String) -> String? {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = unwrapped(ModelReasoning.withoutLeadingThinking(reply, unlessIn: input), unlessIn: source)
        guard !text.isEmpty else { return nil }
        guard RecordingSession.acceptsPolish(of: source, result: text, minShare: minShare, maxShare: maxShare, slack: 0)
        else { return nil }
        guard !text.contains(SummaryPrompt.dictationOpenMarker),
              !text.contains(SummaryPrompt.dictationCloseMarker) else { return nil }
        // What the prompt puts in a marker's place; the person's own text
        // may hold the same words, and then they stay.
        if text.contains(SummaryPrompt.redactedMarker), !source.contains(SummaryPrompt.redactedMarker) { return nil }
        guard !SensitiveDataProtector.containsUnrestoredMarker(text) else { return nil }
        guard sameText(text, as: source) else { return nil }
        return text
    }

    /// `validate` off the main actor: the comparison folds and aligns both
    /// texts word by word, and a 1,200-character dictation is a few
    /// hundred of them.
    @concurrent
    static func validated(_ reply: String, input: String) async -> String? {
        validate(reply, input: input)
    }

    /// The pairs a model wraps an answer in.
    private static let wrappers: [(open: Character, close: Character)] = [
        ("\"", "\""), ("“", "”"), ("«", "»"), ("„", "“"), ("'", "'"), ("‘", "’"), ("`", "`"),
    ]

    /// The text without ONE pair of quotes or a Markdown fence around the
    /// whole of it — only when the dictation has no such character itself
    /// and neither has the inside, so «Привет», — сказал он и «ушёл» keeps
    /// both of its own.
    static func unwrapped(_ text: String, unlessIn source: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6, !source.contains("```") {
            var inside = text.dropFirst(3).dropLast(3)
            // The fence's language tag, when there is one: its first line.
            if let firstBreak = inside.firstIndex(where: \.isNewline),
               !inside[..<firstBreak].contains(where: \.isWhitespace) {
                inside = inside[inside.index(after: firstBreak)...]
            }
            let trimmed = inside.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains("```") { return trimmed }
        }
        guard text.count > 2, let first = text.first, let last = text.last else { return text }
        for pair in wrappers where first == pair.open && last == pair.close {
            guard !source.contains(pair.open), !source.contains(pair.close) else { continue }
            let inside = text.dropFirst().dropLast()
            guard !inside.contains(pair.open), !inside.contains(pair.close) else { continue }
            return inside.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: Same words

    /// How much of a believed answer may be words the dictation didn't
    /// have: a misheard word put right beyond recognition, a number
    /// written in digits, a product's name restored.
    static let maxNewShare = 0.3
    /// Three new words in a row are a sentence of the model's own.
    static let maxNewRun = 2
    /// Words in front of the first one that lines up with the dictation,
    /// or after the last: one or two can be a misheard opening put right,
    /// more is a line added.
    static let maxEdgeRun = 2
    /// How many of the DICTATION's words may be left out in front of what
    /// the reply keeps: «ну, короче, в общем» and the like. Every answer
    /// the corpus hopes for leaves out two at most.
    static let maxUncoveredHead = 3

    /// And how many after it. A reply that is only the first part of what
    /// was said reads as a perfect correction of that part — every word
    /// the person's own, in order — so what it must not do is stop early:
    /// «allow access for Anna but do not give her admin rights» is not
    /// «Allow access for Anna.» Two words in a long dictation (a trailing
    /// «you know», «как-то так»), one in a short one, where two are a
    /// third of what was said. The corpus needs two, once, in 21 words.
    static func maxUncoveredTail(sourceWords: Int) -> Int {
        min(2, max(1, sourceWords / 8))
    }

    // What these numbers are known to refuse that a person would have
    // wanted, each failing safe (the text goes in as recognized). Left as
    // they are until the bench says how often they bite; a place to start
    // the tuning from:
    //  - several product names restored to Latin in one short Russian
    //    sentence: half the words change script (`scriptFlipped`), or
    //    more than `maxNewShare` of them are new;
    //  - a text dense with numbers written out in digits: each number is
    //    a new word, and three in a row are over `maxNewRun`;
    //  - articles or small words added to a short phrase («send report
    //    to client» → «Send the report to the client»): two new words of
    //    six are over the share;
    //  - a first or last word misheard beyond half its letters: nothing
    //    at the edge stands in for it (`similar`);
    //  - two trailing fillers on a dictation under sixteen words, three
    //    or more on any, four or more leading ones
    //    (`maxUncoveredTail`, `maxUncoveredHead`);
    //  - a clause moved to the very start or end of the text.

    private nonisolated enum Script {
        case cyrillic, latin, other
    }

    /// One word of a text, folded for comparing: lower case, no
    /// diacritics, Cyrillic in Latin letters («фигму» and “Figma” are one
    /// letter apart then), ASCII letters and digits only.
    private nonisolated struct Word {
        var folded: [UInt8]
        let script: Script
        var isNumber: Bool
    }

    /// The reply is the dictation's own words, corrected.
    ///
    /// Both texts are folded into words (case, diacritics, punctuation and
    /// script don't count) and compared twice. As a bag: a reply word is
    /// NEW when no word of the dictation is near it — the same, an edit or
    /// two apart, or sharing a stem — and only so many may be new, and so
    /// many in a row. In order: the longest run of words the two have in
    /// common, in sequence, has to be most of the reply, and what the
    /// reply has in front of it or after it must stand in for the
    /// dictation's own first or last words («They're» for a misheard
    /// «their»), not be added to them («Sure, …», «Here is the corrected
    /// text: …», «… I fixed the punctuation»). The other way round too:
    /// the dictation may have only a few words in front of what the reply
    /// keeps, and fewer after it — a reply that is the first half of what
    /// was said is not what was said. And the script must not change
    /// sides: a Russian dictation that comes back mostly in Latin letters
    /// was translated, while a product's name restored inside it leaves it
    /// Russian.
    ///
    /// What this cannot tell is a change of meaning made with the person's
    /// own words: an answer written in the question's words, a «not»
    /// added or dropped, a number or a name one letter off, a clause gone
    /// from the middle. The prompt is what keeps a model from those; this
    /// is the net under it, and under the net the dictation history keeps
    /// the text as it was recognized (`DictationEntry.recognized`).
    static func sameText(_ reply: String, as source: String) -> Bool {
        let r = words(reply)
        let s = words(source)
        guard !r.isEmpty, !s.isEmpty else { return r.isEmpty && s.isEmpty }
        guard !scriptFlipped(from: s, to: r) else { return false }

        let n = r.count, m = s.count
        // Which reply word is near which word of the dictation, asked
        // once per distinct pair.
        var ids: [[UInt8]: Int] = [:]
        func id(_ word: Word) -> Int {
            if let known = ids[word.folded] { return known }
            let next = ids.count
            ids[word.folded] = next
            return next
        }
        let rid = r.map(id), sid = s.map(id)
        var memo: [Int: Bool] = [:]
        var same = [Bool](repeating: false, count: n * m)
        var known = [Bool](repeating: false, count: n)
        for i in 0..<n {
            for j in 0..<m {
                let key = rid[i] &* 100_003 &+ sid[j]
                let isNear: Bool
                if let cached = memo[key] {
                    isNear = cached
                } else {
                    isNear = near(r[i], s[j])
                    memo[key] = isNear
                }
                if isNear {
                    same[i * m + j] = true
                    known[i] = true
                }
            }
        }

        let newCount = known.lazy.filter { !$0 }.count
        guard newCount <= max(1, Int(Double(n) * maxNewShare)) else { return false }
        var run = 0
        for isKnown in known {
            run = isKnown ? 0 : run + 1
            if run > maxNewRun { return false }
        }

        // The longest common subsequence, and which words are in it.
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = same[i * m + j]
                    ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var alignedReply: [Int] = [], alignedSource: [Int] = []
        var i = 0, j = 0
        while i < n, j < m {
            if same[i * m + j], table[i * (m + 1) + j] == table[(i + 1) * (m + 1) + j + 1] + 1 {
                alignedReply.append(i)
                alignedSource.append(j)
                i += 1
                j += 1
            } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        guard let firstReply = alignedReply.first, let lastReply = alignedReply.last,
              let firstSource = alignedSource.first, let lastSource = alignedSource.last else { return false }
        // Most of the reply is the dictation in its own order; the rest
        // may be a clause moved.
        guard alignedReply.count * 2 >= n else { return false }

        // How much of the dictation the reply leaves out at its ends, by
        // the worst reading: the most words that can go from the front
        // with the common sequence as long as it is, and from the back.
        let longest = table[0]
        var uncoveredHead = 0
        for j in 0...m where table[j] == longest { uncoveredHead = j }
        var above = [Int32](repeating: 0, count: m + 1)
        var row = above
        for i in 1...n {
            row[0] = 0
            for j in 1...m {
                row[j] = same[(i - 1) * m + j - 1] ? above[j - 1] + 1 : max(above[j], row[j - 1])
            }
            swap(&above, &row)
        }
        let covered = above.firstIndex(of: longest) ?? m
        guard uncoveredHead <= maxUncoveredHead, m - covered <= maxUncoveredTail(sourceWords: m) else { return false }

        // In front of the first common word and after the last: only what
        // replaces the dictation's own words there.
        let leading = Array(r[..<firstReply]), trailing = Array(r[(lastReply + 1)...])
        guard leading.count <= maxEdgeRun, trailing.count <= maxEdgeRun else { return false }
        // The dictation's own words there, the nearest few.
        let replacedInFront = Array(s[..<firstSource].suffix(4))
        let replacedAtEnd = Array(s[(lastSource + 1)...].prefix(4))
        for word in leading where !word.isNumber {
            guard replacedInFront.contains(where: { similar(word, $0) }) else { return false }
        }
        for word in trailing where !word.isNumber {
            guard replacedAtEnd.contains(where: { similar(word, $0) }) else { return false }
        }
        return true
    }

    /// Most of the dictation's words were in one of Cyrillic and Latin,
    /// and most of the reply's are in the other.
    private static func scriptFlipped(from source: [Word], to reply: [Word]) -> Bool {
        func cyrillicShare(_ words: [Word]) -> Double? {
            let cyrillic = words.lazy.filter { !$0.isNumber && $0.script == .cyrillic }.count
            let latin = words.lazy.filter { !$0.isNumber && $0.script == .latin }.count
            guard cyrillic + latin > 0 else { return nil }
            return Double(cyrillic) / Double(cyrillic + latin)
        }
        guard let before = cyrillicShare(source), let after = cyrillicShare(reply) else { return false }
        return (before > 0.5 && after < 0.5) || (before < 0.5 && after > 0.5)
    }

    /// The same word for the bag: equal; or, from four letters up, one
    /// edit apart (two from seven up); or sharing a stem of five letters
    /// that is most of the longer one. Three letters and under have to be
    /// equal — «a» and «I» are an edit apart too. A number is only itself.
    private static func near(_ a: Word, _ b: Word) -> Bool {
        if a.folded == b.folded { return true }
        if a.isNumber || b.isNumber { return false }
        let shorter = min(a.folded.count, b.folded.count), longer = max(a.folded.count, b.folded.count)
        guard shorter > 3 else { return false }
        let allowed = shorter <= 6 ? 1 : 2
        if distance(a.folded, b.folded, atMost: allowed) <= allowed { return true }
        var stem = 0
        while stem < shorter, a.folded[stem] == b.folded[stem] { stem += 1 }
        return stem >= 5 && stem * 10 >= longer * 6
    }

    /// Looser, for a word that stands in for another at the text's edge:
    /// no more than half of the longer one differs («theyre» for «their»,
    /// not «yes» for «do»).
    private static func similar(_ a: Word, _ b: Word) -> Bool {
        if a.folded == b.folded { return true }
        if a.isNumber || b.isNumber { return false }
        let shorter = min(a.folded.count, b.folded.count), longer = max(a.folded.count, b.folded.count)
        guard shorter >= 2 else { return false }
        let allowed = longer / 2
        return distance(a.folded, b.folded, atMost: allowed) <= allowed
    }

    /// Edit distance, given up on (as `limit + 1`) once it can't be within
    /// `limit`.
    private static func distance(_ a: [UInt8], _ b: [UInt8], atMost limit: Int) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var best = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                best = min(best, current[j])
            }
            if best > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The text's words, folded. An apostrophe inside a word goes with it
    /// («don't» and «dont» are one word); digits that follow digits are
    /// one number («7,99», «25 000», «11:30»).
    private static func words(_ text: String) -> [Word] {
        var out: [Word] = []
        var folds: [String: [UInt8]] = [:]
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            defer { current = "" }
            let folded: [UInt8]
            if let cached = folds[current] {
                folded = cached
            } else {
                folded = fold(current)
                folds[current] = folded
            }
            guard !folded.isEmpty else { return }
            let isNumber = folded.allSatisfy { $0 >= 48 && $0 <= 57 }
            if isNumber, let last = out.indices.last, out[last].isNumber {
                out[last].folded += folded
                return
            }
            out.append(Word(folded: folded, script: script(of: current), isNumber: isNumber))
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’", !current.isEmpty,
                      index + 1 < characters.count, characters[index + 1].isLetter {
                continue
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    private static func fold(_ word: String) -> [UInt8] {
        // «дж» and «кс» the way English spells them, before the standard
        // transliteration makes them «dž» and «ks»: «джире» is then one
        // letter from “Jira”, not three, and «фикс» is “fix”.
        let lowered = word.lowercased()
            .replacingOccurrences(of: "дж", with: "j")
            .replacingOccurrences(of: "кс", with: "x")
        let latin = lowered.applyingTransform(.toLatin, reverse: false) ?? lowered
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.lowercased().utf8.filter { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
    }

    private static func script(of word: String) -> Script {
        guard let scalar = word.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return .other }
        switch scalar.value {
        case 0x0400...0x052F: return .cyrillic
        case 0x0041...0x024F: return .latin
        default: return .other
        }
    }

    // MARK: - Outcome

    nonisolated enum Outcome: Equatable, Sendable {
        /// The corrected text is used.
        case applied
        /// The answer is the text as it was.
        case unchanged
        /// Nothing came inside the deadline.
        case timeout
        /// An answer came and wasn't used.
        case rejected(Rejection)
        /// The request failed: the network, or the provider's own trouble.
        case failed
        /// Nothing was asked — or the provider said it won't, for a reason
        /// that is a state of things rather than a fault: no subscription,
        /// an allowance used up, a yes taken back.
        case skipped(SkipReason)

        var label: String {
            switch self {
            case .applied: "applied"
            case .unchanged: "unchanged"
            case .timeout: "timeout"
            case .rejected(let why): "rejected: \(why.rawValue)"
            case .failed: "failed"
            case .skipped(let why): "skipped: \(why.rawValue)"
            }
        }

        /// The provider didn't answer, as opposed to answering something
        /// unusable or saying why it won't: what `Breaker` counts.
        var isProviderFailure: Bool {
            self == .timeout || self == .failed
        }
    }

    /// What an error from the provider comes to. Only the network and the
    /// provider's own faults are failures (a model that can't be reached
    /// or isn't available among them: an MCP server that didn't answer
    /// comes up under that name). An answer cut off or declined
    /// is an answer; a subscription that isn't there, an allowance used
    /// up, a key that is missing or a yes taken back are states, each with
    /// its own name, and none of them is a reason to stop asking for five
    /// minutes.
    static func outcome(for error: any Error) -> Outcome {
        if let denied = error as? NotPermitted { return .skipped(denied.reason) }
        if error is UnfinishedReply { return .rejected(.stopped) }
        if let ours = error as? DaisySubscriptionError {
            switch ours {
            case .signedOut, .trialUsed, .subscriptionRequired, .consentNeeded: return .skipped(.noSubscription)
            case .dailyLimit: return .skipped(.dailyLimit)
            case .monthlyLimit: return .skipped(.monthlyLimit)
            case .busy: return .failed
            }
        }
        switch error as? SummaryProviderError {
        case .outputTruncated: return .rejected(.truncated)
        case .refused: return .rejected(.refused)
        case .unsupportedLanguage: return .skipped(.language)
        case .missingAPIKey: return .skipped(.notReady)
        case .transcriptTooShort: return .skipped(.short)
        default: return .failed
        }
    }

    /// The error's kind for the log: a name and a status, never its
    /// message — a provider's error body can quote the request.
    static func failureKind(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is NotPermitted { return "not permitted" }
        if let ours = error as? DaisySubscriptionError { return "daisy \(ours)" }
        if let url = error as? URLError { return "url \(url.code.rawValue)" }
        switch error as? SummaryProviderError {
        case .httpError(_, let status, _): return "http \(status)"
        case .missingAPIKey: return "no key"
        case .invalidResponse: return "invalid response"
        case .parseFailed: return "parse"
        case .modelUnavailable: return "model unavailable"
        case .transcriptTooShort: return "too short"
        case .contextOverflow: return "context overflow"
        case .outputTruncated: return "truncated"
        case .refused: return "refused"
        case .streamInterrupted: return "stream interrupted"
        case .timedOut: return "timed out"
        case .unsupportedLanguage: return "language"
        case nil: return String(describing: type(of: error))
        }
    }

    // MARK: - Breaker

    /// A provider that failed or ran out of time three times running is
    /// left alone for five minutes, then tried once: every dictation would
    /// otherwise wait the whole deadline for a service that is down. In
    /// memory only — a restart tries again. The moments come from the
    /// caller, so a test needs no waiting.
    nonisolated struct Breaker: Equatable, Sendable {
        static let threshold = 3
        static let pause: Duration = .seconds(5 * 60)

        private var failures: [SummaryProviderKind: Int] = [:]
        private var pausedUntil: [SummaryProviderKind: ContinuousClock.Instant] = [:]

        init() {}

        /// Whether `kind` may be asked now. After the pause this is the
        /// one trial: it failing pauses again, it answering clears the count.
        func allows(_ kind: SummaryProviderKind, at now: ContinuousClock.Instant) -> Bool {
            pausedUntil[kind].map { now >= $0 } ?? true
        }

        /// Only a timeout or a failure counts, and only an answer ends
        /// the count; a skip — nothing asked, or a state the provider
        /// named — is neither.
        mutating func record(_ outcome: Outcome, for kind: SummaryProviderKind, at now: ContinuousClock.Instant) {
            if case .skipped = outcome { return }
            guard outcome.isProviderFailure else {
                failures[kind] = nil
                pausedUntil[kind] = nil
                return
            }
            let count = (failures[kind] ?? 0) + 1
            failures[kind] = count
            if count >= Self.threshold { pausedUntil[kind] = now + Self.pause }
        }
    }

    // MARK: - Where the text was going

    /// What had the keyboard when the cleanup began: the app, and the
    /// field when Accessibility could name it.
    nonisolated struct InsertionTarget<Field: Equatable>: Equatable {
        var app: pid_t?
        var field: Field?
    }

    /// The person moved on while the answer was awaited: the text must
    /// not be typed into another field or another app. Two fields that
    /// could both be read are compared; when either couldn't (Chromium
    /// shows no focus, a busy app times out) the app in front decides —
    /// the rule `DictationPaste.deliverNow` goes by after its own wait.
    static func targetMoved<Field: Equatable>(from before: InsertionTarget<Field>,
                                              to after: InsertionTarget<Field>) -> Bool {
        if let was = before.field, let now = after.field { return was != now }
        return before.app != after.app
    }

    // MARK: - Running it

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Dictation")
    private static let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "Dictation")

    /// Ask `clean` for the corrected text and give it `deadline` to answer.
    /// Always returns a text to insert: the corrected one when it came in
    /// time and `validate` believes it, `text` itself otherwise.
    ///
    /// The request and the deadline race for one continuation, whoever
    /// comes first — not a task group, which waits for every child and so
    /// for a request that ignores its cancellation. The loser is cancelled
    /// and left to end by itself.
    ///
    /// `deadline` nil: no limit, for the bench, which measures slow
    /// answers instead of cutting them. `kind` is only named in the log.
    static func run<C: Clock<Duration>>(
        _ text: String,
        kind: SummaryProviderKind,
        deadline: Duration? = DictationCleanup.deadline,
        clock: C = ContinuousClock(),
        clean: @escaping @Sendable (String) async throws -> String
    ) async -> (text: String, outcome: Outcome) {
        let started = clock.now
        let interval = signposter.beginInterval("dictation_cleanup")
        let first = FirstAnswer<Result<String, any Error>?>()
        let work = Task<Void, Never> {
            do {
                first.resume(.success(try await clean(text)))
            } catch {
                first.resume(.failure(error))
            }
        }
        let timer = deadline.map { limit in
            Task<Void, Never> {
                try? await clock.sleep(for: limit)
                guard !Task.isCancelled else { return }
                first.resume(nil)
                work.cancel()
            }
        }
        let answer = await first.value()
        timer?.cancel()

        var result = text
        var failure = ""
        let outcome: Outcome
        switch answer {
        case nil:
            outcome = .timeout
        case .failure(let error):
            outcome = Self.outcome(for: error)
            if outcome == .failed { failure = " " + failureKind(error) }
        case .success(let reply):
            if let cleaned = await validated(reply, input: text) {
                // A space more or less at the ends is not a correction.
                if cleaned == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    outcome = .unchanged
                } else {
                    outcome = .applied
                    result = cleaned
                }
            } else {
                outcome = .rejected(.reply)
            }
        }
        signposter.endInterval("dictation_cleanup", interval)
        let ms = milliseconds(started.duration(to: clock.now))
        log.notice("Cleanup \(ms, privacy: .public) ms (\(kind.rawValue, privacy: .public), \(text.count, privacy: .public)→\(result.count, privacy: .public) chars, \(outcome.label, privacy: .public)\(failure, privacy: .public))")
        return (result, outcome)
    }

    /// A dictation that wasn't sent, in the log: without it «why wasn't
    /// this one fixed» has no answer. Not for the switch being off.
    static func logSkip(_ reason: SkipReason, kind: SummaryProviderKind?, chars: Int) {
        guard reason != .off else { return }
        log.notice("Cleanup skipped (\(kind?.rawValue ?? "none", privacy: .public), \(chars, privacy: .public) chars, \(reason.rawValue, privacy: .public))")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// The dictation's language when it can be told from the text, off
    /// the main actor: only Apple's on-device model needs it, to not be
    /// asked for a language it doesn't write.
    @concurrent
    static func language(of text: String) async -> String? {
        LanguageDetector.detect(text)
    }
}

/// One value for whoever comes first; later ones are dropped. The value
/// may arrive before anyone waits for it.
nonisolated private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value, Never>)
        case answered(Value)
        case taken
    }

    private let lock = NSLock()
    private var state = State.empty

    func resume(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>? = lock.withLock {
            switch state {
            case .empty:
                state = .answered(value)
                return nil
            case .waiting(let continuation):
                state = .taken
                return continuation
            case .answered, .taken:
                return nil
            }
        }
        waiter?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = lock.withLock {
                if case .answered(let value) = state {
                    state = .taken
                    return value
                }
                state = .waiting(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

// MARK: - The yes

/// The yes to send dictations to a provider that isn't on this Mac: one
/// per provider kind, and for the place that provider sends text to at the
/// moment it was given (`Summarizer.destination(of:)`: the kind, and for
/// Ollama, LM Studio and an MCP server their address). A provider chosen
/// later has none of its own and inherits nothing; the same provider
/// pointed at another server doesn't use the one it had. A yes stays until
/// it is taken back or the switch goes off, and until then it is listed in
/// Settings with its address, whichever provider is chosen now.
nonisolated struct DictationCleanupConsent {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A yes as it is stored.
    nonisolated struct Grant: Equatable, Hashable, Sendable {
        let kind: SummaryProviderKind
        let destination: String

        /// The address the yes is for, when the provider has one of its
        /// own («10.0.0.5:11434»), and whether its model is a cloud one —
        /// read back out of `Summarizer.destination(kind:…)`. nil for a
        /// provider with one fixed destination.
        var endpoint: (host: String, cloudModel: Bool)? {
            let parts = destination.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 1 else { return nil }
            let address = parts[1]
            let host = address.range(of: "://").map { String(address[$0.upperBound...]) } ?? address
            return (host, parts.dropFirst(2).contains("cloud-model"))
        }
    }

    static func key(_ kind: SummaryProviderKind) -> String {
        "daisy.dictationCleanup.cloudAllowed.\(kind.rawValue)"
    }

    /// Where the «allow sending» notice was last shown for, so it comes
    /// once per provider and not with every dictation.
    static func noticeKey(_ kind: SummaryProviderKind) -> String {
        "daisy.dictationCleanup.consentNoticeShown.\(kind.rawValue)"
    }

    func isAllowed(_ kind: SummaryProviderKind, destination: String) -> Bool {
        guard let stored = defaults.string(forKey: Self.key(kind)), !stored.isEmpty else { return false }
        return stored == destination
    }

    func allow(_ kind: SummaryProviderKind, destination: String) {
        defaults.set(destination, forKey: Self.key(kind))
    }

    /// Takes a yes back; the notice may come again.
    func revoke(_ kind: SummaryProviderKind) {
        defaults.removeObject(forKey: Self.key(kind))
        defaults.removeObject(forKey: Self.noticeKey(kind))
    }

    /// The switch going off takes every yes with it: turning it on again
    /// asks again.
    func revokeAll() {
        for kind in SummaryProviderKind.allCases { revoke(kind) }
    }

    /// Every yes there is, whether or not it is for the provider chosen
    /// now or for the address that provider has now: a yes that would come
    /// back into force with a setting must be seen, and revocable, before
    /// it does.
    func grants() -> [Grant] {
        SummaryProviderKind.allCases.compactMap { kind in
            guard let stored = defaults.string(forKey: Self.key(kind)), !stored.isEmpty else { return nil }
            return Grant(kind: kind, destination: stored)
        }
    }

    /// True once per provider and destination: the first dictation that
    /// wasn't sent for want of a yes says so, the next ones don't.
    func shouldShowNotice(_ kind: SummaryProviderKind, destination: String) -> Bool {
        guard defaults.string(forKey: Self.noticeKey(kind)) != destination else { return false }
        defaults.set(destination, forKey: Self.noticeKey(kind))
        return true
    }
}

// MARK: - What is known of the provider

/// What the cleanup has learned about the providers since launch: the
/// breaker, and an allowance that ran out. In memory only. Observable, so
/// the caption in Settings says why dictations aren't being corrected.
@MainActor
@Observable
final class DictationCleanupStatus {
    static let shared = DictationCleanupStatus()

    /// An allowance the server said is used up, and until when it isn't
    /// asked about again: every dictation would otherwise go to the server
    /// only to be refused.
    struct Hold: Equatable {
        let kind: SummaryProviderKind
        let limit: DictationCleanup.Limit
        let until: ContinuousClock.Instant
    }

    /// A quarter of an hour: an allowance comes back at the server's
    /// midnight, which the Mac doesn't know, and one refused request in
    /// fifteen minutes is the price of noticing.
    nonisolated static let limitHold: Duration = .seconds(15 * 60)

    private(set) var breaker = DictationCleanup.Breaker()
    private(set) var hold: Hold?

    init() {}

    func isPaused(_ kind: SummaryProviderKind, at now: ContinuousClock.Instant = .now) -> Bool {
        !breaker.allows(kind, at: now)
    }

    func limit(for kind: SummaryProviderKind, at now: ContinuousClock.Instant = .now) -> DictationCleanup.Limit? {
        guard let hold, hold.kind == kind, now < hold.until else { return nil }
        return hold.limit
    }

    /// What a request came to. The breaker counts timeouts and failures;
    /// an allowance used up is held; an answer clears both.
    func record(_ outcome: DictationCleanup.Outcome, for kind: SummaryProviderKind, at now: ContinuousClock.Instant = .now) {
        breaker.record(outcome, for: kind, at: now)
        switch outcome {
        case .skipped(.dailyLimit): hold = Hold(kind: kind, limit: .daily, until: now + Self.limitHold)
        case .skipped(.monthlyLimit): hold = Hold(kind: kind, limit: .monthly, until: now + Self.limitHold)
        case .applied, .unchanged, .rejected:
            if hold?.kind == kind { hold = nil }
        case .timeout, .failed, .skipped:
            break
        }
    }
}

@MainActor
extension DictationCleanup {
    /// Things as they stand now, read from the app's own objects: what
    /// `DictationPaste` gates a dictation on, and what the row in Settings
    /// writes its caption from.
    static func standing(
        summarizer: Summarizer? = nil, defaults: UserDefaults = .standard,
        account: DaisyAccountStore? = nil, status: DictationCleanupStatus? = nil,
        now: ContinuousClock.Instant = .now
    ) -> Standing {
        // nil is the app's own; a default of `.shared` would be read off
        // the main actor.
        let summarizer = summarizer ?? .shared
        let account = account ?? .shared
        let status = status ?? .shared
        var standing = Standing(enabled: defaults.bool(forKey: enabledKey))
        guard let route = summarizer.dictationCleanupRoute else { return standing }
        standing.route = route
        standing.isLocal = summarizer.isEffectivelyLocal(route.kind)
        standing.allowed = DictationCleanupConsent(defaults: defaults).isAllowed(route.kind, destination: route.destination)
        if route.kind == .daisySubscription {
            // From the last status read, never a request of its own: a
            // dictation doesn't wait on the account.
            standing.subscriptionActive = account.isSignedIn && account.hasAcknowledgedCloudDisclosure
                && account.subscription?.active == true
        }
        standing.providerMissing = route.kind == summarizer.providerKind && summarizer.availability.missing != nil
        standing.limit = status.limit(for: route.kind, at: now)
        standing.paused = status.isPaused(route.kind, at: now)
        return standing
    }
}

// MARK: - The caption in Settings

/// What the line under «Fix dictation by context» says: where dictations
/// go, or why they aren't being corrected — the gate's own answer
/// (`DictationCleanup.standingSkip`), so the line can't promise what the
/// gate refuses. The view only puts words to it.
nonisolated enum DictationCleanupCaption: Equatable, Sendable {
    /// The provider can't answer while someone waits.
    case tooSlow(SummaryProviderKind)
    /// The Daisy Subscription isn't there: signed out or not active.
    case needsSubscription
    /// On, and the provider isn't on this Mac and has no yes: nothing is sent.
    case notSentUntilAllowed(DictationCleanup.Route)
    /// The text and up to forty vocabulary words go there.
    case sent(DictationCleanup.Route)
    case notSetUp(SummaryProviderKind)
    case limitReached(DictationCleanup.Limit)
    case paused(SummaryProviderKind)
    case onThisMac
    /// Apple's model: only the languages it writes.
    case appleIntelligence
    /// Apple's model, and the dictation language set in Settings is one it
    /// doesn't write.
    case appleCannotWrite(language: String)

    /// `interactive`: the provider chosen, for naming one that can't do
    /// it. `dictationLanguage`: the language pinned for dictation, nil for
    /// Auto. `appleWrites`: whether Apple's model writes a language.
    static func caption(
        for standing: DictationCleanup.Standing, interactive: SummaryProviderKind,
        dictationLanguage: String?, appleWrites: (String) -> Bool
    ) -> DictationCleanupCaption {
        // With the switch off the line says what turning it on would do,
        // so the gate is asked as if it were on.
        var asIfOn = standing
        asIfOn.enabled = true
        let reason = DictationCleanup.standingSkip(asIfOn)
        guard let route = standing.route else { return .tooSlow(interactive) }
        switch reason {
        case .provider: return .tooSlow(interactive)
        case .noSubscription: return .needsSubscription
        // Off, there is nothing being withheld yet: turning it on asks.
        case .consent: return standing.enabled ? .notSentUntilAllowed(route) : .sent(route)
        case .notReady where standing.enabled: return .notSetUp(route.kind)
        case .dailyLimit where standing.enabled: return .limitReached(.daily)
        case .monthlyLimit where standing.enabled: return .limitReached(.monthly)
        case .paused where standing.enabled: return .paused(route.kind)
        default: break
        }
        guard standing.isLocal else { return .sent(route) }
        guard route.kind == .appleIntelligence else { return .onThisMac }
        if let dictationLanguage, !appleWrites(dictationLanguage) { return .appleCannotWrite(language: dictationLanguage) }
        return .appleIntelligence
    }

    /// The «Allow sending to …» button goes with this line only.
    var offersToAllow: Bool {
        if case .notSentUntilAllowed = self { return true }
        return false
    }
}

// MARK: - One dictation, step by step

/// What happens to a dictation between recognition and the field, with
/// every effect handed in, so the order and the bookkeeping can be tested
/// without a history file, a voice profile or a field to type into.
/// `DictationPaste` hands in the real ones.
@MainActor
struct DictationSteps {
    struct Cleaned {
        var text: String
        var outcome: DictationCleanup.Outcome
        /// The person moved to another field or app while the answer was
        /// awaited.
        var targetMoved = false
    }

    /// The person's vocabulary and the brand layer, counted.
    var correct: (String) -> String
    /// Into the dictation history; the entry's id, to replace it later.
    var recordHistory: (String) -> UUID?
    var replaceHistory: (UUID, String) -> Void
    /// Into the voice-profile corpus.
    var appendCorpus: (String) -> Void
    var clean: (String) async -> Cleaned
    /// The person's spellings put back into a text a model wrote.
    var respell: (_ cleaned: String, _ corrected: String) -> String
    /// One more fix for the «fixes made by Daisy» count.
    var countCleanup: () -> Void
    var deliver: (String, _ targetMoved: Bool) async -> Void
    /// The entry is on its way to the field, and then there: a re-paste
    /// asked for in between must not put it in a second time
    /// (`DictationOrder.isInFlight`).
    var began: (UUID) -> Void = { _ in }
    var landed: (UUID) -> Void = { _ in }

    /// The text is in the history and the corpus BEFORE the answer is
    /// awaited: quitting, or a crash, during those seconds must not take
    /// the dictation with it. The corpus keeps that text whatever comes —
    /// the profile learns the person's words, not a model's — and the
    /// history's entry is replaced when the corrected text is what lands,
    /// because a re-paste puts back what was pasted.
    func run(_ transcript: String) async {
        let corrected = correct(transcript)
        let entry = recordHistory(corrected)
        if let entry { began(entry) }
        appendCorpus(corrected)
        let cleaned = await clean(corrected)
        var pasted = corrected
        if cleaned.outcome == .applied {
            // A model may write a term its own way: the person's rules
            // have the last word.
            let respelled = respell(cleaned.text, corrected)
            if respelled != corrected {
                pasted = respelled
                if let entry { replaceHistory(entry, pasted) }
                countCleanup()
            }
        }
        await deliver(pasted, cleaned.targetMoved)
        if let entry { landed(entry) }
    }
}

/// Dictations go through their steps one after another, in the order they
/// were said: the cleanup may take up to its deadline, and a short
/// dictation said right after a long one must not overtake it into the
/// field.
///
/// It also knows which history entries are still on their way. The text
/// is in the history before the answer is awaited (so nothing is lost),
/// which makes it the newest entry while it hasn't landed yet: «Paste my
/// last dictation» pressed in those seconds would put the recognized text
/// in, and the corrected one would follow it. For an entry in flight the
/// re-paste does nothing — the dictation is about to land by itself, once.
@MainActor
final class DictationOrder {
    private var last: Task<Void, Never>?
    private var inFlight: Set<UUID> = []

    func began(_ entry: UUID) { inFlight.insert(entry) }
    func landed(_ entry: UUID) { inFlight.remove(entry) }
    func isInFlight(_ entry: UUID) -> Bool { inFlight.contains(entry) }

    func run(_ work: @escaping @MainActor () async -> Void) async {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        last = task
        await task.value
    }
}
