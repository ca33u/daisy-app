//
//  GrokAPISummarizer.swift
//  Daisy
//
//  SummaryProvider for Grok on xAI's own API, on the person's API key
//  (Keychain). Added 2026-11-03 (Egor, option (а) of the vault note
//  business/projects/daisy/2026-11-03-grok-provider-research.md). Named
//  after the model, not the company: xAI became SpaceXAI and then SpaceXSI
//  in 2026, while the API stayed at api.x.ai.
//
//  The Responses API, not chat completions: xAI marks
//  `/v1/chat/completions` deprecated ("legacy endpoint, limited updates")
//  and puts new features on `/v1/responses`. Its edges:
//
//   • Responses are stored for 30 days unless the request says otherwise,
//     so every request sends `store: false` — a meeting is never kept for
//     a later turn. (The 30-day abuse log below is separate.)
//   • The reply is held to the envelope's schema (`text.format`, strict
//     json_schema), as Anthropic's is: `constrainedReplyJSON`, two levels,
//     no `$ref`, all fields required — within what xAI enforces.
//     `CloudSummaryDTO` stays lenient behind it.
//   • Reasoning comes as output items and events of its own and is never
//     read as the answer. grok-4.3 takes `reasoning.effort: none`;
//     grok-4.7/4.6/4.5 can't stop reasoning, and `low` is their least.
//     `max_output_tokens` caps only the visible answer, so the summary's
//     8192 isn't eaten by thinking. Reasoning is billed as output and on
//     xAI isn't counted in `output_tokens` — see `TokenSpend.responsesAPI`.
//   • No temperature (xAI's guide warns off changing it), no tools, no
//     stop or penalties (an error on reasoning models).
//   • Every response carries `x-zero-data-retention: true|false`. The last
//     one is kept for Settings, which says whether the person's xAI team
//     has Zero Data Retention on.
//
//  Privacy: xAI keeps API requests and responses for 30 days to check for
//  abuse, and never trains on them without explicit permission; a team
//  admin can turn on Zero Data Retention (docs.x.ai/developers/faq/security,
//  2026-11-03). The default endpoint promises no processing region; no
//  country is written, as for the other cloud providers.
//
//  Verified against docs.x.ai (models, pricing, Responses API reference,
//  reasoning, structured outputs, best practices, debugging, security FAQ)
//  on 2026-11-03, without a key — the stream shape and error bodies are
//  the documented ones, to be checked on a live key.
//

import Foundation
import os

nonisolated struct GrokAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .grok

    /// API model name. See `availableModels`.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "GrokSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?
    /// Where a reply's `x-zero-data-retention` goes; tests keep it away
    /// from the real prefs.
    let recordRetention: @Sendable (Bool) -> Void

    init(
        model: String = defaultModelID,
        urlSession: URLSession = .shared,
        apiKeyOverride: String? = nil,
        recordRetention: @escaping @Sendable (Bool) -> Void = { GrokAPISummarizer.recordZeroDataRetention($0, defaults: .standard) }
    ) {
        self.model = Self.resolvedModelID(model)
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
        self.recordRetention = recordRetention
    }

    func isReady() async -> Bool {
        if let key = apiKeyOverride ?? KeychainStore.get(account: SecretKey.grokAPIKey), !key.isEmpty {
            return true
        }
        return false
    }

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.grokAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: Self.providerName)
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        // Refuse before paying for a 400: the room for the meeting is the
        // window less the answer budget.
        if let window = Self.contextTokens(for: model) {
            let approx = LocalContextGuard.estimatedTokens(promptChars: systemPrompt.count + userPrompt.count)
            let room = window - Self.answerTokens
            if approx > room {
                throw SummaryProviderError.modelUnavailable(
                    provider: Self.providerName,
                    reason: String(localized: "this meeting is longer than \(Self.plainName(for: model)) can read (about \(approx) tokens of \(room))."))
            }
        }

        // The schema goes in as its own text (`constrainedReplyJSON` says
        // why its order matters), spliced over this placeholder once the
        // body is serialized — as AnthropicAPISummarizer does.
        let schemaPlaceholder = "daisy-reply-schema-\(UUID().uuidString)"
        var body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": [
                ["role": "user", "content": userPrompt]
            ],
            // Not kept for a later turn: see the header.
            "store": false,
            "max_output_tokens": Self.answerTokens,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": MeetingSummaryJSONSchema.identifier,
                    "schema": schemaPlaceholder,
                    "strict": true
                ]
            ],
            // Streamed: see CloudStreaming.
            "stream": true
        ]
        if let effort = Self.reasoningEffort(for: model) {
            body["reasoning"] = ["effort": effort]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total (streamed — see CloudStreaming): grok-4.7 may
        // reason for a while before the answer starts.
        request.timeoutInterval = 300
        let serialized = try JSONSerialization.data(withJSONObject: body, options: [])
        let schema = MeetingSummaryJSONSchema.constrainedReplyJSON(includesTitle: task.asksForTitle)
        request.httpBody = Data(String(decoding: serialized, as: UTF8.self)
            .replacingOccurrences(of: "\"\(schemaPlaceholder)\"", with: schema).utf8)

        let text: String
        do {
            // Every 2xx carries the header, whatever its answer turns out to be.
            text = try await CloudStreaming.responsesText(
                request, session: urlSession, provider: Self.providerName, kind: .grok, model: model, log: log,
                opened: { response in
                    if let retention = Self.zeroDataRetention(in: response) { recordRetention(retention) }
                })
        } catch SummaryProviderError.httpError(_, let status, let message) {
            throw Self.worded(status: status, body: message, model: model)
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: Self.providerName,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Errors

    static let providerName = "Grok"

    /// The HTTP failures a person can do something about, in words
    /// (docs.x.ai/developers/debugging); the reasons follow «Grok: » (the
    /// case's own prefix). xAI documents no status of its own for a team
    /// out of credits: it is read off the body of a 403, or of a 429 should
    /// it come as one (that one has been retried by then, unbilled). The
    /// bodies are to be checked on a live key.
    static func worded(status: Int, body: String, model: String) -> SummaryProviderError {
        let lowered = body.lowercased()
        let outOfCredits = lowered.contains("credit") || lowered.contains("spending limit")
        switch status {
        case 403 where outOfCredits, 429 where outOfCredits:
            return .modelUnavailable(provider: providerName, reason: String(localized: "your xAI team is out of credits or at its spending limit. Top up at console.x.ai and try again."))
        case 401, 403:
            return .modelUnavailable(provider: providerName, reason: String(localized: "the API key wasn’t accepted. Check it in \(SettingsRow.summaryProvider.path)."))
        case 429:
            return .modelUnavailable(provider: providerName, reason: String(localized: "too many requests. Try again in a minute."))
        case 404,
             400 where lowered.contains("model") && (lowered.contains("not found") || lowered.contains("does not exist")):
            return .modelUnavailable(provider: providerName, reason: String(localized: "no model \(model) — it may have been retired. Pick another model in \(SettingsRow.summaryProvider.path)."))
        // The window check before sending estimates; the server counts.
        case 400 where lowered.contains("context length") || lowered.contains("maximum context")
                || lowered.contains("prompt length") || lowered.contains("prompt is too long"):
            return .modelUnavailable(provider: providerName, reason: String(localized: "this meeting is longer than \(plainName(for: model)) can read."))
        default:
            return .httpError(provider: providerName, status: status, body: body)
        }
    }

    // MARK: - Endpoint

    /// docs.x.ai: base URL https://api.x.ai/v1, Responses API.
    static let endpoint = URL(string: "https://api.x.ai/v1/responses")!

    // MARK: - Zero Data Retention

    /// What the last reply said about Zero Data Retention: "on", "off",
    /// or absent before the first reply. Cleared when the key changes.
    static let zeroDataRetentionKey = "daisy.grok.zeroDataRetention"

    /// `x-zero-data-retention`, documented as "true" or "false" on every
    /// response; nil when it's missing or says something else.
    static func zeroDataRetention(in response: HTTPURLResponse?) -> Bool? {
        switch response?.value(forHTTPHeaderField: "x-zero-data-retention")?
            .trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    static func recordZeroDataRetention(_ on: Bool, defaults: UserDefaults) {
        defaults.set(on ? "on" : "off", forKey: zeroDataRetentionKey)
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// docs.x.ai/developers/models and /pricing, 2026-11-03. Per 1M under a
    /// 200K-token prompt: grok-4.3 $1.25 in / $2.50 out, 1M context;
    /// grok-4.7 $2 / $6, 500K context.
    ///
    /// grok-4.3 is the default (Egor, 03.11): about $0.03 an hour of
    /// meeting with reasoning off. grok-4.7 is xAI's flagship and can't
    /// stop reasoning, which is billed as output.
    static let availableModels: [(id: String, label: String)] = [
        ("grok-4.3", String(localized: "Grok 4.3 (recommended)")),
        ("grok-4.7", String(localized: "Grok 4.7 (highest quality, priciest)")),
    ]

    static let defaultModelID = "grok-4.3"

    static let answerTokens = 8192

    /// `reasoning.effort` per model, nil to send none: grok-4.3 turns
    /// reasoning off with `none`; grok-4.7/4.6/4.5 can't, and `low` is
    /// their least. Other ids (grok-4.20, a model typed by hand) get the
    /// model's own default rather than a value it may refuse.
    static func reasoningEffort(for model: String) -> String? {
        switch model.lowercased() {
        case "grok-4.3", "grok-4.3-latest": "none"
        case "grok-4.7", "grok-4.6", "grok-4.5": "low"
        default: nil
        }
    }

    /// Context window in tokens, nil for an id Daisy doesn't list.
    static func contextTokens(for model: String) -> Int? {
        switch model.lowercased() {
        case "grok-4.3", "grok-4.3-latest": 1_000_000
        case "grok-4.7", "grok-4.6", "grok-4.5": 500_000
        default: nil
        }
    }

    static func plainName(for model: String) -> String {
        switch model.lowercased() {
        case "grok-4.3", "grok-4.3-latest": "Grok 4.3"
        case "grok-4.7": "Grok 4.7"
        case "grok-4.6": "Grok 4.6"
        case "grok-4.5": "Grok 4.5"
        default: model
        }
    }

    static func resolvedModelID(_ stored: String) -> String {
        let id = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? defaultModelID : id
    }
}
