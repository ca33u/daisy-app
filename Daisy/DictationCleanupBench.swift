// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DictationCleanupBench.swift
//  Daisy
//
//  A hidden way to measure «Fix dictation by context» on a file of phrases
//  (28.11.2026), next to DaisyLLMSmoke's flags:
//
//      Daisy.app/Contents/MacOS/Daisy --daisy-dictation-cleanup-bench <corpus.jsonl> \
//          [--runs n] [--allow-cloud] [--with-terms | --no-terms] [--no-deadline]
//
//  Each line of the corpus is a JSON object `{"id","lang","raw","want"}`
//  (scripts/dictation-cleanup/corpus.jsonl: phrases written for this, no
//  real dictations). Every phrase goes the way a dictation goes
//  (`DictationPaste`): the vocabulary and the brand layer, the length
//  rules, the language told from the text, the request held to the
//  deadline, the answer checked, the spellings put back — with the
//  provider chosen in Settings. So the numbers are the product's. What
//  belongs to a person at a keyboard is left out: the switch and the
//  stored yes, the field, the history, the voice profile, the breaker.
//  Each phrase is printed with its time and outcome; then the median and
//  the nearest-rank p90 of the times, and how many ended each way. `want`
//  is for the eye: nothing is scored here.
//
//  A dictation sends up to forty entries of the person's vocabulary with
//  its text, and a prompt without them is shorter than the product's. So
//  by default the bench sends forty made-up ones in their place (product
//  and company names, `syntheticTerms`): the prompt is the size the
//  product sends, and nothing personal goes with a measurement.
//  `--with-terms` sends the person's own vocabulary instead, as a real
//  dictation does; `--no-terms` sends none. The run says which it was.
//  The person's vocabulary corrects the phrases on this Mac in every
//  case, as it does a dictation. `--no-deadline` lets a slow answer finish, so
//  its time is measured instead of being cut at 2.5 s. A provider that
//  isn't on this Mac is refused without `--allow-cloud`: the flag is this
//  run's yes, and the yes stored for dictation is neither read nor written.
//
//  It runs before DaisyApp sets anything up (no window, no Sentry, no MCP
//  port), so it can run next to the Daisy in /Applications. The provider's
//  key or session is read from the Keychain as the app reads it, which a
//  properly signed build can and an ad-hoc one can't; for the latter,
//  `DAISY_BENCH_ANTHROPIC_KEY` (one's own Anthropic key) or
//  `DAISY_BENCH_SESSION` (a Daisy session, for the subscription) in the
//  environment stand in. Their values are never printed, and a session
//  given this way that the server refuses never signs the app's own
//  account out.
//
//  Exit codes: 0 done, 64 usage, 66 the corpus can't be read, 77 a cloud
//  provider without `--allow-cloud`, 78 the provider can't be used.
//

import Foundation

nonisolated enum DictationCleanupBench {
    static let flag = "--daisy-dictation-cleanup-bench"

    nonisolated struct Phrase: Decodable, Sendable, Equatable {
        let id: String
        let lang: String?
        let raw: String
        let want: String?
    }

    /// Returns at once without the flag; with it, never returns.
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: flag) else { return }
        let rest = Array(arguments[(index + 1)...])
        guard let path = rest.first, !path.hasPrefix("--") else {
            say("usage: Daisy \(flag) <corpus.jsonl> [--runs n] [--allow-cloud] [--with-terms | --no-terms] [--no-deadline]")
            exit(64)
        }
        Task.detached { exit(await run(corpus: path, arguments: rest)) }
        dispatchMain()
    }

    /// Which vocabulary entries go with the phrases.
    enum TermsMode: Equatable {
        /// Forty made-up ones: the default.
        case synthetic
        /// The person's own, as a dictation sends them (`--with-terms`).
        case own
        /// None (`--no-terms`).
        case none

        /// `--no-terms` wins over `--with-terms`: asked for both, the
        /// bench sends less rather than more.
        init(_ arguments: [String]) {
            if arguments.contains("--no-terms") {
                self = .none
            } else if arguments.contains("--with-terms") {
                self = .own
            } else {
                self = .synthetic
            }
        }

        var label: String {
            switch self {
            case .synthetic: "synthetic"
            case .own: "your vocabulary"
            case .none: "none"
            }
        }
    }

    /// Forty product and company names, as many as a dictation sends at
    /// most (`SummaryPrompt.dictationCleanupTermLimit`), so the prompt is
    /// as long as the product's. Public names, nobody's vocabulary.
    static let syntheticTerms = [
        "Figma", "Slack", "Jira", "GitHub", "Notion", "Linear", "Zoom", "Kubernetes", "Docker", "Postgres",
        "Redis", "Grafana", "Sentry", "Vercel", "Stripe", "Xcode", "TestFlight", "Swift", "TypeScript", "Python",
        "Terraform", "Datadog", "PagerDuty", "Confluence", "Miro", "Loom", "Airtable", "Zapier", "HubSpot", "Salesforce",
        "Intercom", "Mixpanel", "Amplitude", "Tableau", "Snowflake", "BigQuery", "Cloudflare", "Supabase", "Firebase", "OpenTelemetry",
    ]

    /// The corpus: one JSON object per line; empty lines are skipped.
    static func phrases(from text: String) throws -> [Phrase] {
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { try decoder.decode(Phrase.self, from: Data($0.utf8)) }
    }

    /// The middle value; the mean of the two middle ones for an even count.
    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Nearest rank: the smallest value with at least `share` of the
    /// values at or below it.
    static func percentile(_ values: [Int], share: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((share * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: option), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func run(corpus path: String, arguments: [String]) async -> Int32 {
        let phrases: [Phrase]
        do {
            phrases = try Self.phrases(from: String(contentsOfFile: path, encoding: .utf8))
        } catch {
            say("can't read \(path): \(error.localizedDescription)")
            return 66
        }
        guard !phrases.isEmpty else {
            say("no phrases in \(path)")
            return 66
        }
        let runs = max(1, value(after: "--runs", in: arguments).flatMap(Int.init) ?? 1)
        let deadline: Duration? = arguments.contains("--no-deadline") ? nil : DictationCleanup.deadline

        let summarizer = await MainActor.run { Summarizer.shared }
        // Read once: the flag below is a yes to this provider at this
        // address, and every request is held to it.
        guard let route = await summarizer.dictationCleanupRoute else {
            let chosen = await summarizer.interactiveProviderKind
            say("\(chosen.rawValue) doesn't correct dictation: choose another provider in Settings → AI")
            return 78
        }
        let kind = route.kind
        if await !summarizer.isEffectivelyLocal(kind), !arguments.contains("--allow-cloud") {
            say("\(kind.rawValue) isn't on this Mac: pass --allow-cloud to send the corpus to it")
            return 77
        }
        // A key or a session from the environment, for a build that can't
        // read the Keychain. Named, never printed.
        let environment = ProcessInfo.processInfo.environment
        var provider: (any SummaryProvider)?
        if kind == .anthropic, let key = environment["DAISY_BENCH_ANTHROPIC_KEY"], !key.isEmpty {
            provider = AnthropicAPISummarizer(model: AnthropicAPISummarizer.dictationCleanupModelID, apiKeyOverride: key)
            say("using the key in DAISY_BENCH_ANTHROPIC_KEY")
        } else if kind == .daisySubscription, let session = environment["DAISY_BENCH_SESSION"], !session.isEmpty {
            provider = DaisySubscriptionSummarizer(sessionOverride: session, subscribedOverride: true)
            say("using the session in DAISY_BENCH_SESSION")
        }
        if provider == nil, await !summarizer.isReady(for: .interactive) {
            let why = await summarizer.availability.reason ?? "it isn't set up, or this build can't read its key from the Keychain"
            say("\(kind.rawValue) can't be used: \(why)")
            return 78
        }

        // What goes with each phrase in place of the vocabulary entries a
        // dictation sends: made-up ones unless told otherwise.
        let mode = TermsMode(arguments)
        let terms: [String]
        switch mode {
        case .synthetic: terms = syntheticTerms
        case .none: terms = []
        case .own:
            terms = await MainActor.run {
                Array(DictationDictionary.shared.biasTerms().prefix(SummaryPrompt.dictationCleanupTermLimit))
            }
        }
        say("\(phrases.count) phrases × \(runs) on \(kind.rawValue), terms: \(mode.label) (\(terms.count) sent), deadline \(deadline.map { "\(DictationCleanup.milliseconds($0)) ms" } ?? "none")")

        var times: [Int] = []
        var outcomes: [String: Int] = [:]
        let clock = ContinuousClock()
        for _ in 0..<runs {
            for phrase in phrases {
                let started = clock.now
                let (text, outcome) = await process(phrase.raw, route: route, deadline: deadline, terms: terms, provider: provider)
                let ms = DictationCleanup.milliseconds(started.duration(to: clock.now))
                times.append(ms)
                outcomes[outcome.label, default: 0] += 1
                print("\(phrase.id)\t\(ms) ms\t\(outcome.label)")
                print("  raw:     \(phrase.raw)")
                print("  cleaned: \(text)")
            }
        }
        print("")
        print("median \(median(times) ?? 0) ms · p90 \(percentile(times, share: 0.9) ?? 0) ms · \(times.count) requests")
        for (label, count) in outcomes.sorted(by: { $0.key < $1.key }) {
            print("\(label): \(count)")
        }
        return 0
    }

    /// One phrase the way a dictation goes, from recognized text to what
    /// would be inserted: `DictationPaste`'s own steps, without the
    /// history, the corpus, the counters and the field.
    @MainActor
    private static func process(
        _ raw: String, route: DictationCleanup.Route, deadline: Duration?, terms: [String],
        provider: (any SummaryProvider)?
    ) async -> (text: String, outcome: DictationCleanup.Outcome) {
        let paste = DictationPaste.shared
        let corrected = paste.correct(raw, counting: false)
        let cleaned = await paste.cleanedByContext(corrected, mode: .bench(route: route, deadline: deadline, terms: terms, provider: provider))
        guard cleaned.outcome == .applied else { return (corrected, cleaned.outcome) }
        return (paste.respell(cleaned.text, afterModelFrom: corrected), cleaned.outcome)
    }
}
