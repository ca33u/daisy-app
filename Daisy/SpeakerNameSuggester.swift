// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SpeakerNameSuggester.swift
//  Daisy
//
//  Who is "Remote B"? Diarization can tell voices apart but cannot
//  name them; voice fingerprints only recognize people the user has
//  already named once. That leaves the common case unsolved — a first
//  meeting with three people from the invite, and a transcript full of
//  "спасибо, Прия" and "Alex, can you take that one?".
//
//  This pass reads the finished transcript alongside the invite's
//  attendee list and proposes label → name. It runs after
//  `TranscriptPolisher`, so the names in the text have already been
//  restored to their canonical spelling and match the invite.
//
//  **Nothing here is ever applied automatically.** Proposals go to the
//  `speaker_suggestions.json` sidecar, where the session's
//  Name-the-speakers card renders each one with a Confirm and a
//  Dismiss. That is a deliberate ceiling on the damage: a wrong name
//  in a transcript is worse than no name at all — it is a quotation
//  attributed to a real person who did not say it, and it propagates
//  into the summary, the follow-up draft, and anything auto-sent.
//  "Remote B" is honest; "Priya" might not be.
//
//  The guard that makes the proposals safe is an allow-list, not a
//  prompt: a suggestion survives only if it resolves to a name from
//  THIS meeting's invite. The model cannot introduce a name, and it
//  cannot move a name in from another meeting — the worst it can do is
//  propose the wrong one of the people who were actually there, which
//  the user then declines with one click.
//

import Foundation
import os

nonisolated enum SpeakerNameSuggester {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SpeakerNames")

    /// How much transcript the model gets to read. Introductions sit at
    /// the top and hand-offs / goodbyes at the bottom, so the sample is
    /// taken from both ends rather than truncating the tail — the
    /// middle of a meeting is where names are used LEAST (everyone
    /// already knows who's talking).
    static let transcriptSampleBudget = 6_000

    /// One request, so a single ceiling rather than the polish's
    /// per-chunk and total pair.
    static let deadlineSeconds: Double = 25

    // MARK: - Prompt context

    /// Plain `Sendable` scalars for the hop into the `nonisolated`
    /// providers, same contract as `TranscriptPolisher.PromptContext`.
    struct PromptContext: Sendable {
        /// Canonical display names from the invite. Doubles as the
        /// allow-list — a proposal that doesn't resolve to one of these
        /// is discarded.
        let attendees: [String]
        /// Remote diarization labels present in the transcript ("A",
        /// "B", …) that still have no name.
        let labels: [String]
    }

    // MARK: - Entry point

    /// Ask for label → name, and return only what survives the
    /// allow-list. Never throws; every failure returns fewer proposals.
    static func suggest(
        transcript: String,
        context: PromptContext,
        turns: [Turn],
        summarize: @escaping @Sendable (String, SummaryTask) async throws -> MeetingSummary
    ) async -> [String: String] {
        guard !context.labels.isEmpty, !context.attendees.isEmpty else { return [:] }

        guard let reply = await TranscriptPolisher.withDeadline(seconds: deadlineSeconds, operation: {
            try await summarize(transcript, .speakerNames(context)).clientFollowUp
        }) else {
            log.info("Speaker-name pass failed or timed out — no suggestions")
            return [:]
        }

        let proposed = parseAssignments(reply)
        let allowed = filter(proposed, context: context)
        // "Never guess": the reply having named someone is not the same
        // as the conversation having shown who they are. Re-derive the
        // evidence from the transcript ourselves rather than trusting
        // the model to have honoured the prompt's evidence rules.
        let accepted = allowed.filter { label, name in
            let supported = hasNamingEvidence(label: label, name: name, turns: turns)
            if !supported {
                log.info("Dropped a proposal for \(label, privacy: .public) — the conversation doesn't show who they are")
            }
            return supported
        }
        log.info("Speaker-name pass: \(proposed.count, privacy: .public) proposed, \(allowed.count, privacy: .public) on the invite, \(accepted.count, privacy: .public) with evidence")
        return accepted
    }

    // MARK: - Turns

    /// One utterance, reduced to what this pass cares about: who said
    /// it and what was said. `label` is nil for the person recording —
    /// dual-channel puts them on the mic stream, and they have no
    /// diarization label to name.
    struct Turn: Sendable {
        let label: String?
        let text: String
    }

    /// Flatten segments into turns. Mic-side segments are KEPT (unlabeled)
    /// because the vocative that names someone is usually spoken by the
    /// user ("thanks, Priya") and both the model and the evidence check
    /// need the turn it attaches to.
    static func turns(_ segments: [TranscriptSegment]) -> [Turn] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let flat = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            switch segment.source {
            case .microphone:  return Turn(label: nil, text: flat)
            case .systemAudio: return Turn(label: segment.speakerId ?? "?", text: flat)
            }
        }
    }

    // MARK: - Transcript sampling

    /// Render turns as `A: text` lines, sampled from both ends to fit
    /// `budget`.
    static func sampleTranscript(
        _ segments: [TranscriptSegment],
        budget: Int = transcriptSampleBudget
    ) -> String {
        sampleTranscript(turns: turns(segments), budget: budget)
    }

    static func sampleTranscript(turns: [Turn], budget: Int = transcriptSampleBudget) -> String {
        let lines = turns.map { "\($0.label ?? "—"): \($0.text)" }
        guard !lines.isEmpty else { return "" }

        let total = lines.reduce(0) { $0 + $1.count + 1 }
        guard total > budget else { return lines.joined(separator: "\n") }

        // Head gets the larger share: introductions ("hi, this is
        // Priya") are the single richest source of names in a meeting.
        var head: [String] = []
        var headBudget = budget * 3 / 5
        for line in lines {
            guard headBudget - line.count > 0 else { break }
            head.append(line)
            headBudget -= line.count + 1
        }
        var tail: [String] = []
        var tailBudget = budget - (budget * 3 / 5)
        for line in lines.reversed() {
            guard tailBudget - line.count > 0 else { break }
            tail.append(line)
            tailBudget -= line.count + 1
        }
        // A single utterance longer than the whole budget takes neither
        // loop (both break on the first line), which would return "" and
        // silently skip the pass. One long unbroken segment is a real
        // shape — a short call where VAD never split — so truncate it
        // rather than dropping the meeting.
        if head.isEmpty && tail.isEmpty {
            return String(lines[0].prefix(budget))
        }

        // Overlapping ends on a short-but-over-budget transcript would
        // duplicate lines; trim the tail to what the head didn't take.
        let headCount = head.count
        let tailSlice = tail.reversed().suffix(max(0, lines.count - headCount))
        guard !tailSlice.isEmpty else { return head.joined(separator: "\n") }
        return (head + ["[…]"] + tailSlice).joined(separator: "\n")
    }

    // MARK: - Reply parsing

    /// Parse `A = Priya Raman` lines into `[label: name]`. Unrecognized
    /// lines are ignored rather than failing the parse — unlike the
    /// polish there is no line-for-line contract to protect here, and
    /// the allow-list below is the real guard. `?`, `unknown` and empty
    /// values mean "the model declined", which is a valid answer.
    static func parseAssignments(_ reply: String) -> [String: String] {
        var result: [String: String] = [:]
        // Labels the reply named more than once. A model that answers
        // "A = Priya" and then "A = Alex" has contradicted itself about
        // that speaker; keeping whichever came last would be picking a
        // side at random. The label is dropped — the others in the same
        // reply still stand, since a contradiction about one speaker
        // says nothing about the rest.
        var contradicted: Set<String> = []
        for rawLine in reply.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let label = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            let name = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            // Labels are the single letters diarization produces. A
            // longer left-hand side is prose that happened to contain
            // an equals sign.
            guard label.count == 1, label.first?.isLetter == true else { continue }
            let key = label.uppercased()
            let lowered = name.lowercased()
            guard !name.isEmpty, name != "?",
                  lowered != "unknown", lowered != "неизвестно" else { continue }
            if result[key] != nil, result[key] != name { contradicted.insert(key) }
            result[key] = name
        }
        for key in contradicted { result.removeValue(forKey: key) }
        return result
    }

    // MARK: - Allow-list

    /// Keep only proposals that name a real attendee of this meeting,
    /// for a label that actually needs one, uniquely.
    static func filter(_ proposed: [String: String], context: PromptContext) -> [String: String] {
        let labels = Set(context.labels)
        var byLabel: [String: String] = [:]
        for (label, raw) in proposed {
            guard labels.contains(label) else { continue }
            guard let canonical = canonicalName(raw, in: context.attendees) else {
                log.info("Dropped a proposed name that isn't on this invite")
                continue
            }
            byLabel[label] = canonical
        }

        // One name, one voice. If the model put the same person behind
        // two labels it was guessing at least once, and we have no way
        // to tell which — so neither is offered.
        var owners: [String: [String]] = [:]
        for (label, name) in byLabel { owners[name, default: []].append(label) }
        for (name, labels) in owners where labels.count > 1 {
            log.info("Dropped \(labels.count, privacy: .public) proposals that named the same attendee")
            for label in labels { byLabel.removeValue(forKey: label) }
            _ = name
        }
        return byLabel
    }

    /// Resolve a proposed name to the invite's spelling, or nil if it
    /// isn't on the invite. Delegates to `SpeakerNameMatching`, which
    /// owns the one-way merge rules shared with the calendar → profile
    /// lookup.
    static func canonicalName(_ raw: String, in attendees: [String]) -> String? {
        SpeakerNameMatching.resolve(raw, in: attendees)
    }

    // MARK: - Evidence ("never guess")

    /// How many times someone must be addressed by name, next to their
    /// own turn, before that counts as knowing who they are. One is a
    /// coincidence — a name landing beside a turn proves nothing when
    /// people talk about absent colleagues constantly.
    static let requiredAddressCount = 2

    /// Does the conversation actually SHOW that `label` is `name`?
    ///
    /// Two things count, and nothing else does:
    ///
    ///   • **Self-introduction** — the speaker says the name about
    ///     THEMSELVES ("hi, this is Priya"). One is enough; nobody
    ///     introduces themselves as someone else.
    ///   • **Being addressed** — the name is used as a VOCATIVE in a
    ///     turn adjacent to one of theirs, `requiredAddressCount` times.
    ///
    /// Both halves need their qualifier, and neither is optional:
    ///
    ///   - A name inside the speaker's own turn is not an introduction.
    ///     "I'll check with Priya and get back to you" would otherwise
    ///     certify whoever said it AS Priya.
    ///   - A name in an adjacent turn is not a form of address.
    ///     "did you send Priya the deck?" / "Priya needs it today"
    ///     mention someone who may not even be on the call, and two of
    ///     those beside the same speaker is an ordinary meeting.
    ///
    /// That second failure — treating talk ABOUT someone as evidence of
    /// who is SPEAKING — is the single most common way to get this
    /// wrong, and both guards exist to close it.
    ///
    /// Matching is on whole tokens, case-insensitively, against the full
    /// name and its given name. Deliberately literal — a Russian name in
    /// an oblique case ("спросил Прию") is talking ABOUT someone rather
    /// than TO them, so not matching it is the behaviour we want.
    static func hasNamingEvidence(label: String, name: String, turns: [Turn]) -> Bool {
        let forms = nameForms(name)
        guard !forms.isEmpty else { return false }

        var addressCount = 0
        for (index, turn) in turns.enumerated() {
            guard forms.contains(where: { mentions($0, in: turn.text) }) else { continue }
            if turn.label == label {
                if forms.contains(where: { isSelfIntroduction($0, in: turn.text) }) { return true }
                continue
            }
            guard forms.contains(where: { isVocative($0, in: turn.text) }) else { continue }
            let neighbours = [index - 1, index + 1]
                .filter { turns.indices.contains($0) }
                .map { turns[$0].label }
            if neighbours.contains(label) { addressCount += 1 }
        }
        return addressCount >= requiredAddressCount
    }

    /// Introduction cues, as token runs that may immediately precede the
    /// name. Kept to phrases whose whole job is presenting a person, so
    /// that a bare "я" or "it's" can't turn a passing mention into an
    /// introduction.
    private static let introductionCues: [[String]] = [
        ["this", "is"], ["i", "m"], ["im"], ["i", "am"],
        ["my", "name", "is"], ["name", "is"], ["speaking"],
        ["это"], ["меня", "зовут"], ["я"], ["на", "связи"],
    ]

    /// True when the name is presented as the speaker's own — an
    /// introduction cue sits immediately before it ("this is Priya",
    /// "меня зовут Прия"), or "speaking" immediately after it.
    static func isSelfIntroduction(_ form: String, in text: String) -> Bool {
        let tokens = tokenize(text)
        let needle = tokenize(form)
        guard !needle.isEmpty else { return false }
        for start in occurrences(of: needle, in: tokens) {
            for cue in introductionCues where start >= cue.count {
                if Array(tokens[(start - cue.count)..<start]) == cue { return true }
            }
            // "Priya speaking" — the trailing English form.
            let after = start + needle.count
            if after < tokens.count, tokens[after] == "speaking" { return true }
        }
        return false
    }

    /// True when the name is used to ADDRESS someone rather than to talk
    /// about them: set off by a comma or dash on the left, and closed by
    /// a comma, sentence-ending punctuation, or the end of the turn on
    /// the right.
    ///
    /// "спасибо, Прия" ✓ · "Прия, посмотри макеты" ✓ (turn start counts
    /// as the left boundary) · "did you send Priya the deck?" ✗ ·
    /// "Priya needs it today" ✗ · "I'll ask Priya." ✗ (no left boundary).
    ///
    /// This misses the comma-less "thanks Priya" that English speakers
    /// write casually. That's the intended trade: a missed vocative
    /// costs the user one manual rename, and a false one puts a real
    /// person's name on someone else's words.
    static func isVocative(_ form: String, in text: String) -> Bool {
        let scalars = Array(text.lowercased())
        let needleTokens = tokenize(form)
        guard !needleTokens.isEmpty else { return false }
        let tokens = tokenize(text)
        let spans = tokenSpans(text.lowercased())
        guard spans.count == tokens.count else { return false }

        for start in occurrences(of: needleTokens, in: tokens) {
            let end = start + needleTokens.count - 1
            let before = scalars[..<spans[start].lowerBound].reversed()
                .first { !$0.isWhitespace }
            let after = scalars[spans[end].upperBound...]
                .first { !$0.isWhitespace }
            let leftOpen = before == nil || before == "," || before == "—" || before == "-" || before == ":"
            let rightClosed = after == nil || after == "," || after == "." || after == "!" || after == "?"
            if leftOpen && rightClosed { return true }
        }
        return false
    }

    /// The written forms worth looking for: the full name, and the
    /// given name when it's long enough not to be an initial.
    static func nameForms(_ name: String) -> [String] {
        guard let normalized = SpeakerNameMatching.normalize(name) else { return [] }
        var forms = [normalized]
        if let given = normalized.split(separator: " ").first, given.count >= 3 {
            let givenName = String(given)
            if givenName != normalized { forms.append(givenName) }
        }
        return forms
    }

    /// Whole-token, case-insensitive containment. Substring matching
    /// would count "Alexander" as a mention of "Alex", and "Прияткин"
    /// as one of "Прия".
    static func mentions(_ form: String, in text: String) -> Bool {
        !occurrences(of: tokenize(form), in: tokenize(text)).isEmpty
    }

    /// Split on anything that isn't a letter or digit — the SAME rule
    /// for the needle and the haystack, which is what lets "O'Brien",
    /// "Anne-Marie" and "Jean-Luc Picard" match at all. Splitting the
    /// needle on spaces alone (as this once did) left the apostrophe in
    /// the needle and stripped it from the text, so every name with
    /// internal punctuation silently failed to match.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Start indices where `needle` appears as a run inside `tokens`.
    private static func occurrences(of needle: [String], in tokens: [String]) -> [Int] {
        guard !needle.isEmpty, tokens.count >= needle.count else { return [] }
        return (0...(tokens.count - needle.count)).filter {
            Array(tokens[$0..<($0 + needle.count)]) == needle
        }
    }

    /// Character ranges of each token in `text`, in the same order
    /// `tokenize` returns them. Lets the vocative check look at the
    /// punctuation immediately around a match — which tokenizing threw
    /// away, and which is the entire signal it needs.
    private static func tokenSpans(_ text: String) -> [Range<Int>] {
        let characters = Array(text)
        var spans: [Range<Int>] = []
        var start: Int? = nil
        for index in characters.indices {
            let isWord = characters[index].isLetter || characters[index].isNumber
            if isWord, start == nil { start = index }
            if !isWord, let open = start { spans.append(open..<index); start = nil }
        }
        if let open = start { spans.append(open..<characters.count) }
        return spans
    }
}
