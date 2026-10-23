//
//  PreMeetingBrief.swift
//  Daisy
//
//  Local pre-meeting brief. Before a calendar meeting, Daisy assembles a
//  short "what you need in your head walking in" brief from the user's
//  OWN past recorded sessions with the same people — matched by attendee
//  email, linked calendar-event title, or meeting title. The dossier of
//  past notes is handed to the selected summary provider under the brief
//  prompt (`SummaryPrompt.briefContext`), reusing the entire provider +
//  decode pipeline and the `MeetingSummary` output type.
//
//  Privacy: fully local whenever the summary provider is local (Apple
//  Intelligence / Ollama / LM Studio). The optional online-research
//  augmentation (`AppSettings.preMeetingBriefResearchOnline`) is the only
//  path that touches the network, is off by default, and is a no-op
//  without an Anthropic API key. See `AttendeeWebResearch`.
//

import Foundation
import Observation
import os

/// A generated brief for one upcoming meeting. `summary` reuses the
/// canonical `MeetingSummary` shape (rendered by the same outline UI as
/// a normal summary), repurposed by the brief prompt.
struct PreMeetingBrief: Sendable, Equatable {
    let summary: MeetingSummary
    /// IDs of the past sessions the brief was built from — newest first.
    let sourceSessionIDs: [String]
    /// Whether an online-research block was folded into the dossier.
    let usedOnlineResearch: Bool
    /// Public sources cited by the online-research pass, if any.
    let webSources: [WebSource]
    let generatedAt: Date
}

/// A single web citation from the optional online-research pass.
/// `nonisolated` — constructed by the `nonisolated` `AttendeeWebResearch`
/// and consumed on the main actor, like the other cross-actor value types
/// (`MeetingSummary`, `CloudSummaryDTO`).
nonisolated struct WebSource: Sendable, Equatable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
}

@Observable
@MainActor
final class PreMeetingBriefStore {
    static let shared = PreMeetingBriefStore()

    enum State: Sendable, Equatable {
        case idle
        case generating
        case ready(PreMeetingBrief)
        /// No past session matched these people — nothing to brief from.
        case noHistory
        /// Pre-meeting briefs are turned off in Settings → Meetings. A
        /// distinct state (not `.unavailable`) because it's the one
        /// "can't brief" reason the user can fix from the card itself.
        case disabled
        /// A cloud provider is selected: waiting for the user to tap
        /// "Generate" before any data is sent. Carries the provider name.
        case needsConsent(String)
        /// Provider couldn't run (e.g. Apple Intelligence unavailable,
        /// missing API key). Carries a user-facing reason.
        case unavailable(String)
        case failed(String)
    }

    /// Keyed by a stable per-meeting identity (see `key(for:)`).
    private(set) var states: [String: State] = [:]

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "PreMeetingBrief")

    /// The generation currently running for a meeting, if any.
    ///
    /// Owned by the STORE, not by the view that asked for it. The card
    /// calls `prepare` from `.task(id:)`, which SwiftUI cancels whenever
    /// the row collapses, the day re-renders, or the next meeting takes
    /// over — and a run cancelled between "state = .generating" and the
    /// first `try await` left `.generating` behind with nothing running.
    /// Every later `prepare` then hit the "already generating" early
    /// return, so the card spun forever with no work in flight (Egor,
    /// 2026-07-28). An unstructured `Task` is not a child of the caller,
    /// so view cancellation can no longer strand the state; this map is
    /// also the honest answer to "is something actually running?".
    @ObservationIgnored
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Bumped every time a run starts for a key. A run only writes state
    /// while it still holds the current number — so a superseded run
    /// can't clobber its successor's result, and (unlike comparing
    /// history signatures) there is no case where the loser returns
    /// having written nothing at all.
    @ObservationIgnored
    private var generation: [String: Int] = [:]

    /// Signature of the matched session set the current brief was built
    /// from — lets us skip regeneration unless the underlying history
    /// changed (a new matching session was recorded).
    @ObservationIgnored
    private var builtSignatures: [String: String] = [:]

    private init() {}

    /// Stable identity for an upcoming meeting. Prefer the provider-side
    /// external id; fall back to the local EK id; last resort title+start
    /// so two different meetings never collide.
    nonisolated static func key(for meeting: DaisyMeeting) -> String {
        if let ext = meeting.externalID, !ext.isEmpty { return "ext:\(ext)" }
        if !meeting.localID.isEmpty { return "loc:\(meeting.localID)" }
        return "ts:\(meeting.title)|\(Int(meeting.startDate.timeIntervalSince1970))"
    }

    func state(for meeting: DaisyMeeting) -> State {
        states[Self.key(for: meeting)] ?? .idle
    }

    /// Idempotent: prepare a brief when appropriate. With a LOCAL summary
    /// provider this auto-generates; with a CLOUD provider it stops at
    /// `.needsConsent` so past-session excerpts never leave the Mac without
    /// an explicit tap. Safe to call from `.task`/`onAppear` repeatedly.
    func prepare(for meeting: DaisyMeeting, settings: AppSettings) async {
        await generate(for: meeting, settings: settings, force: false)
    }

    /// Explicit user consent — tapped "Generate" on a cloud provider.
    func confirmAndGenerate(for meeting: DaisyMeeting, settings: AppSettings) async {
        await generate(for: meeting, settings: settings, force: true)
    }

    private func generate(for meeting: DaisyMeeting, settings: AppSettings, force: Bool) async {
        let key = Self.key(for: meeting)

        // Feature switched off. This used to `return` silently, leaving
        // the state at `.idle` — which the card draws exactly like
        // `.generating`, i.e. an eternal spinner under a "Prep for …"
        // header (Egor, 2026-07-28). Say what's wrong instead; the card
        // offers the switch.
        //
        // Drain first: a run started before the switch was flipped would
        // otherwise finish, overwrite `.disabled` with a brief the user
        // just turned off — and keep talking to a cloud provider on the
        // way there.
        guard settings.preMeetingBriefEnabled else {
            await drain(key)
            states[key] = .disabled
            return
        }

        // Match strength depends on where the data would go. A CLOUD
        // provider only accepts STRONG matches (a shared attendee email),
        // never an ambiguous title-only match — "Weekly sync" could belong
        // to a different client. Local providers may use weaker matches.
        // Effective-local (configured endpoint, not provider kind) —
        // remote-pointed MCP/Ollama must not auto-run. See Summarizer.
        let providerLocal = Summarizer.shared.providerIsEffectivelyLocal
        let now = Date()
        let matches = Self.matchingSessions(
            for: meeting,
            in: SessionStore.shared.sessions,
            now: now,
            limit: 3,
            requireStrong: !providerLocal
        )
        guard !matches.isEmpty else {
            states[key] = .noHistory
            return
        }

        let signature = matches.map(\.id).joined(separator: ",")
        // Don't stack a second generation on top of one that is really
        // running. Keyed off `inFlight`, NOT off a `.generating` state:
        // the state is a drawing instruction and can go stale, a live
        // Task cannot. JOIN it rather than bail — every other exit from
        // this function leaves a state behind, and a caller that pre-set
        // `.idle` (see `regenerate`) would otherwise be left drawing a
        // spinner for a run it never learns the end of.
        if let running = inFlight[key] {
            await running.value
            return
        }
        // Already have a brief for this exact history.
        if builtSignatures[key] == signature, case .ready = states[key] ?? .idle { return }

        // Cloud provider → require an explicit tap before sending anything.
        if !providerLocal && !force {
            states[key] = .needsConsent(Summarizer.shared.providerKind.shortName)
            return
        }

        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        states[key] = .generating
        builtSignatures[key] = signature

        // Hand the slow part to a task the store owns, then await it. The
        // caller gets the same "finished when this returns" behaviour, but
        // cancelling the caller no longer abandons a `.generating` state
        // with nothing behind it.
        // Strong `self` on purpose: the store is a singleton, and the
        // `defer` in `run` is what clears `inFlight`.
        let task = Task {
            await self.run(
                meeting: meeting, settings: settings,
                key: key, generation: gen, matches: matches, now: now
            )
        }
        inFlight[key] = task
        await task.value
    }

    /// Stop whatever is running for `key` and wait for it to unwind, so
    /// the caller can take ownership of the key. Loops because a run can
    /// start while we're awaiting the previous one.
    private func drain(_ key: String) async {
        while let existing = inFlight[key] {
            existing.cancel()
            await existing.value
        }
    }

    /// State write from inside a run — ignored once a newer run has taken
    /// the key, so a superseded generation can't overwrite a fresher
    /// result (or resurrect a spinner).
    private func setState(_ state: State, key: String, generation gen: Int) {
        guard generation[key] == gen else { return }
        states[key] = state
    }

    /// The slow half of `generate`: availability → optional web research
    /// → provider call. Always leaves `states[key]` in a terminal state.
    private func run(
        meeting: DaisyMeeting,
        settings: AppSettings,
        key: String,
        generation gen: Int,
        matches: [StoredSession],
        now: Date
    ) async {
        defer { inFlight[key] = nil }
        // Every state write below goes through this, so a run that has
        // been superseded quietly does nothing instead of half-writing.
        func publish(_ state: State) { setState(state, key: key, generation: gen) }
        func allowRetry() {
            guard generation[key] == gen else { return }
            builtSignatures[key] = nil
        }

        // Provider must be ready before we keep the spinner up. Without
        // this, runProbe below can block indefinitely — a local summary
        // model still initializing, or an MCP/Ollama endpoint pointed at a
        // host that never answers — leaving the card stuck forever on
        // "Assembling from your past meetings…" (Egor 2026-07-23). Mirror
        // MorningBrief: resolve availability first and bail to
        // `.unavailable` rather than hang. `.unknown` (not yet probed)
        // proceeds optimistically — the timeouts below are the backstop.
        //
        // The probe itself gets a ceiling: `isReady()` for an MCP or
        // Ollama endpoint is a network round-trip, and a host that accepts
        // the connection but never answers would hang HERE, before the
        // generation timeout could ever apply. On timeout we proceed
        // optimistically rather than declare the provider dead.
        if Summarizer.shared.availability == .unknown {
            _ = try? await Self.withTimeout(seconds: 15) {
                await Summarizer.shared.refreshAvailability()
            }
        }
        if case .unavailable(let why) = Summarizer.shared.availability {
            publish(.unavailable(why))
            allowRetry()
            return
        }

        // Optional online research (opt-in, Anthropic-key gated). Its own
        // ceiling: `CloudHTTPRetry` retries a 45 s request, so the worst
        // case here is minutes — outside the generation timeout below,
        // which only wraps the provider call.
        var webBlock: String? = nil
        var webSources: [WebSource] = []
        var usedWeb = false
        if settings.preMeetingBriefResearchOnline {
            let researched: AttendeeWebResearch.Result?? = try? await Self.withTimeout(seconds: 60) {
                await AttendeeWebResearch.research(for: meeting)
            }
            if let research = researched ?? nil {
                webBlock = research.text
                webSources = research.sources
                usedWeb = !research.text.isEmpty
            }
        }

        let localeHint = Self.briefLocaleHint(from: matches)
        let dossier = Self.buildDossier(matches: matches, webContext: webBlock)
        let info = SummaryPrompt.BriefPromptInfo(
            meetingTitle: meeting.title,
            attendees: meeting.attendees,
            lastMetPhrase: Self.relativePhrase(from: matches.first?.startedAt, to: now),
            includesWebContext: usedWeb
        )

        do {
            // Hard wall-clock ceiling so a reachable-but-wedged provider
            // can't leave the card spinning forever (the backstop the
            // availability check above can't cover).
            let summary = try await Self.withTimeout(seconds: 60) {
                try await Summarizer.shared.runProbe(
                    transcript: dossier,
                    title: meeting.title,
                    localeHint: localeHint,
                    task: .preMeetingBrief(info)
                )
            }
            let brief = PreMeetingBrief(
                summary: summary,
                sourceSessionIDs: matches.map(\.id),
                usedOnlineResearch: usedWeb,
                webSources: webSources,
                generatedAt: Date()
            )
            publish(.ready(brief))
            log.info("Brief ready for \(meeting.title, privacy: .public) from \(matches.count) past session(s)")
        } catch {
            // Cancelled — `drain` superseded this run, and whoever called
            // it writes the next state. `publish` is a no-op by then
            // (a newer generation owns the key), which is the point.
            if error is CancellationError || Task.isCancelled {
                publish(.idle)
                allowRetry()
                return
            }
            // Timed out — provider never answered. Surface a clear,
            // retryable failure instead of an endless spinner.
            if error is BriefTimeoutError {
                publish(.failed(String(localized: "The brief took too long and was stopped — tap retry.")))
                allowRetry()
                log.error("Brief timed out for \(meeting.title, privacy: .public)")
                return
            }
            // Provider-unready errors get the softer "unavailable" state
            // (nothing the user did wrong); everything else is "failed".
            let msg = error.localizedDescription
            if let provErr = error as? SummaryProviderError {
                switch provErr {
                case .modelUnavailable, .missingAPIKey, .unsupportedLanguage:
                    publish(.unavailable(msg))
                default:
                    publish(.failed(msg))
                }
            } else {
                publish(.failed(msg))
            }
            allowRetry()
            log.error("Brief failed for \(meeting.title, privacy: .public): \(msg, privacy: .public)")
        }
    }

    /// Force a regenerate (user tapped refresh on the brief card). An
    /// explicit tap counts as consent for a cloud provider.
    func regenerate(for meeting: DaisyMeeting, settings: AppSettings) async {
        let key = Self.key(for: meeting)
        // Let a run that's still going finish unwinding BEFORE restarting,
        // otherwise the old run discards its own result and the card is
        // left spinning on a `.generating` nobody owns.
        await drain(key)
        builtSignatures[key] = nil
        states[key] = .idle
        await generate(for: meeting, settings: settings, force: true)
    }

    // MARK: - Timeout

    struct BriefTimeoutError: Error {}

    /// Race an async operation against a wall-clock deadline: returns the
    /// operation's result if it wins, throws `BriefTimeoutError` if the
    /// deadline does (and cancels the still-running operation). Backstops
    /// brief generation so a wedged provider can't spin the card forever.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BriefTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Matching (pure, nonisolated)

    /// Past sessions that plausibly involve the same people as `meeting`,
    /// scored and returned newest-first, capped at `limit`. Only sessions
    /// strictly before `now` with a real signal (shared attendee email,
    /// same linked event title, or a strong title match) qualify — we
    /// never brief off an unrelated session just because it's recent.
    /// - Parameter requireStrong: when true, ONLY a shared attendee email
    ///   qualifies a session (used for cloud providers — a title-only match
    ///   is too ambiguous to risk sending another client's history off the
    ///   Mac). When false, weaker linked-title / session-title matches also
    ///   count (safe for a local provider).
    nonisolated static func matchingSessions(
        for meeting: DaisyMeeting,
        in sessions: [StoredSession],
        now: Date,
        limit: Int,
        requireStrong: Bool = false
    ) -> [StoredSession] {
        let meetingEmails = Set(meeting.attendeeEmails.map { $0.lowercased() })
        let meetingTitleNorm = normalizeTitle(meeting.title)

        struct Scored { let session: StoredSession; let score: Int }
        var scored: [Scored] = []

        // The tour's demo meeting is nobody's history.
        for s in sessions where s.startedAt < now && !s.isDemo {
            var score = 0
            // Strongest — and the ONLY signal allowed for cloud: a shared
            // attendee email. Unique enough to trust cross-session.
            if !meetingEmails.isEmpty {
                let sessionEmails = Set(s.meetingAttendeeEmails.map { $0.lowercased() })
                if !meetingEmails.isDisjoint(with: sessionEmails) { score += 100 }
            }
            if !requireStrong {
                // Weaker, title-based signals — local-only, since titles
                // like "Weekly sync" collide across different people.
                if let linked = s.linkedEventTitle, !linked.isEmpty,
                   normalizeTitle(linked) == meetingTitleNorm, !meetingTitleNorm.isEmpty {
                    score += 60
                }
                if !meetingTitleNorm.isEmpty {
                    let st = normalizeTitle(s.title)
                    if st == meetingTitleNorm { score += 40 }
                    else if !st.isEmpty && (st.contains(meetingTitleNorm) || meetingTitleNorm.contains(st)) { score += 20 }
                }
            }
            if score > 0 { scored.append(Scored(session: s, score: score)) }
        }

        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.session.startedAt > b.session.startedAt
            }
            .prefix(limit)
            .map(\.session)
    }

    /// Lowercased, punctuation-stripped, common meeting-noise-word-free
    /// title for fuzzy comparison. "Weekly sync · Maria (Acme)" and
    /// "weekly sync maria acme" collapse to the same token soup.
    nonisolated static func normalizeTitle(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let noise: Set<String> = ["the", "a", "an", "with", "and", "call", "meeting", "sync", "chat", "1", "1on1", "catchup", "catch", "up"]
        let tokens = String(cleaned)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty && !noise.contains($0) }
        return tokens.joined(separator: " ")
    }

    // MARK: - Dossier (pure, nonisolated)

    /// Build the dossier the brief prompt summarizes: newest-first blocks
    /// of past-session notes, optionally prefixed with a web-context
    /// block. Total length is bounded so token cost stays sane.
    nonisolated static func buildDossier(matches: [StoredSession], webContext: String?) -> String {
        let maxChars = 12_000
        var out = ""

        if let web = webContext, !web.isEmpty {
            out += "=== WEB CONTEXT (public, gathered online) ===\n"
            out += web.prefix(2_500)
            out += "\n\n"
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none

        for s in matches {
            var block = "### \(df.string(from: s.startedAt)) — \(s.title)\n"
            let attendees = s.meetingAttendees.filter { !$0.isEmpty }
            if !attendees.isEmpty {
                block += "Attendees: \(attendees.joined(separator: ", "))\n"
            }
            if let summary = s.summary, !Self.summaryIsEmpty(summary) {
                block += flatten(summary: summary)
            } else {
                // No summary on disk — fall back to a transcript slice.
                let preview = s.transcriptPreview.isEmpty
                    ? String(s.transcriptText.prefix(1_200))
                    : s.transcriptPreview
                block += "Transcript excerpt: \(preview)\n"
            }
            block += "\n"

            if out.count + block.count > maxChars { break }
            out += block
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func summaryIsEmpty(_ s: MeetingSummary) -> Bool {
        s.summary.isEmpty && s.sections.isEmpty && s.actionItems.isEmpty
    }

    /// Render a `MeetingSummary` into compact indented text for the
    /// dossier (the LLM reads notes far better than re-serialized JSON).
    nonisolated static func flatten(summary: MeetingSummary) -> String {
        var out = ""
        if !summary.summary.isEmpty { out += "\(summary.summary)\n" }
        for section in summary.sections {
            out += "• \(section.title)\n"
            for bullet in section.bullets {
                out += flatten(bullet: bullet, depth: 1)
            }
        }
        if !summary.actionItems.isEmpty {
            out += "Open/next items:\n"
            for item in summary.actionItems { out += "  - \(item)\n" }
        }
        if !summary.clientFollowUp.isEmpty {
            out += "Follow-up sent: \(summary.clientFollowUp.prefix(400))\n"
        }
        return out
    }

    nonisolated static func flatten(bullet: SummaryBullet, depth: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        var out = "\(indent)- \(bullet.text)\n"
        for child in bullet.children {
            out += flatten(bullet: child, depth: depth + 1)
        }
        return out
    }

    // MARK: - Locale + recency (pure, nonisolated)

    /// Pick a locale hint for the brief from the matched sessions — the
    /// most-recent session's locale if it's a concrete 2-letter code,
    /// else nil (let the model follow the dossier's language).
    nonisolated static func briefLocaleHint(from matches: [StoredSession]) -> String? {
        for s in matches {
            let loc = s.locale.lowercased()
            guard !loc.isEmpty, loc != "auto" else { continue }
            return String(loc.prefix(2))  // "ru", "en" (from "en-US"), …
        }
        return nil
    }

    /// "yesterday" / "3 days ago" / "2 weeks ago" / "on Mar 5" — a light
    /// recency phrase for the brief header. Nil in → nil out.
    nonisolated static func relativePhrase(from date: Date?, to now: Date) -> String? {
        guard let date else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        switch days {
        case ..<0: return nil
        case 0: return "earlier today"
        case 1: return "yesterday"
        case 2...13: return "\(days) days ago"
        case 14...59: return "\(days / 7) weeks ago"
        default:
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return "on \(df.string(from: date))"
        }
    }
}
