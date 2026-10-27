//
//  DeepSeekAPISummarizer.swift
//  Daisy
//
//  SummaryProvider for DeepSeek's own API — its OpenAI-compatible Chat
//  Completions endpoint on the person's API key (Keychain). Added
//  2026-10-27 (Egor, package D of the plan in the vault,
//  business/projects/daisy/2026-10-27-yandex-provider-plan.md §11). Not
//  the DeepSeek model YandexGPT also hosts: this goes to DeepSeek itself.
//
//  A separate file rather than a base URL on the OpenAI adapter, for the
//  reasons KimiAPISummarizer's header gives. DeepSeek's edges:
//
//   • Both models think by default (effort high) and bill the thinking
//     as output. A summary gains little from it, so every request says
//     `thinking: {type: disabled}` — documented for both, and the budget
//     is then the summary alone. `reasoning_content` deltas, if any, are
//     not content and the stream accumulator never reads them.
//   • `stream_options.include_usage` is documented: usage is the last
//     chunk before [DONE]. While a request waits the server sends SSE
//     comments (`: keep-alive`), which keep the idle timer quiet, and it
//     closes a request whose inference hasn't started in 10 minutes.
//   • No temperature (ignored when thinking, and the default suits a
//     summary), no response_format: `json_object` "may occasionally
//     return empty content", and the prompt asking for JSON plus
//     `CloudSummaryDTO.decode` already do the job, as for Gemini.
//   • A bad key answers 401 in plain text («Authentication Fails»), not
//     JSON; an empty balance is 402.
//   • Two finish reasons of its own: `insufficient_system_resource` and
//     `aborted` — said in words by CloudStreaming.
//
//  The privacy wording is the same as for the other cloud providers — no
//  country (Egor, 27.10). DeepSeek's privacy policy allows using requests
//  to train its models and documents no API opt-out; the Settings footer
//  says that, as Gemini's does for a free-tier key.
//
//  Verified against api-docs.deepseek.com (create-chat-completion,
//  guides/thinking_mode, guides/json_mode, quick_start/pricing,
//  rate_limit, error_codes, updates) on 2026-10-27, without a key.
//

import Foundation
import os

nonisolated struct DeepSeekAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .deepseek

    /// API model name. See `availableModels`.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DeepSeekSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.model = Self.resolvedModelID(model)
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        if let key = apiKeyOverride ?? KeychainStore.get(account: SecretKey.deepseekAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.deepseekAPIKey),
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

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            // Thinking off: see the header. The budget is the summary
            // alone — what a long meeting's summary needed elsewhere
            // (8192, Kimi); DeepSeek allows up to 393,216.
            "thinking": ["type": "disabled"],
            "max_tokens": Self.answerTokens,
            // Streamed: see CloudStreaming.
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total (streamed — see CloudStreaming); keep-alive
        // comments count as bytes while the request waits.
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let text: String
        do {
            // geminiCompatible: the largest reading of the output side, in
            // case any thinking is billed outside completion_tokens.
            text = try await CloudStreaming.openAICompatibleText(
                request, session: urlSession, provider: Self.providerName, kind: .deepseek, model: model,
                log: log, spend: TokenSpend.geminiCompatible(from:))
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

    static let providerName = "DeepSeek"

    /// The HTTP failures a person can do something about, in words
    /// (api-docs.deepseek.com/quick_start/error_codes); the reasons follow
    /// «DeepSeek: » (the case's own prefix). The bodies are checked on a
    /// live key (plan step 0).
    static func worded(status: Int, body: String, model: String) -> SummaryProviderError {
        let lowered = body.lowercased()
        switch status {
        case 401, 403:
            return .modelUnavailable(provider: providerName, reason: String(localized: "the API key wasn’t accepted. Check it in \(SettingsRow.summaryProvider.path)."))
        case 402:
            return .modelUnavailable(provider: providerName, reason: String(localized: "the balance has run out. Top it up at platform.deepseek.com and try again."))
        case 429:
            return .modelUnavailable(provider: providerName, reason: String(localized: "too many requests. Try again in a minute."))
        // DeepSeek's own body for an unknown model is «Model Not Exist».
        case 400 where lowered.contains("model not exist"), 404:
            return .modelUnavailable(provider: providerName, reason: String(localized: "no model \(model) — it may have been retired. Pick another model in \(SettingsRow.summaryProvider.path)."))
        // The window check before sending estimates; the server counts.
        case 400 where lowered.contains("context length") || lowered.contains("maximum context"):
            return .modelUnavailable(provider: providerName, reason: String(localized: "this meeting is longer than \(plainName(for: model)) can read."))
        default:
            return .httpError(provider: providerName, status: status, body: body)
        }
    }

    // MARK: - Endpoint

    /// api-docs.deepseek.com: OpenAI-format base URL https://api.deepseek.com.
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    // MARK: - Catalog of model IDs offered in Settings

    /// quick_start/pricing, 2026-10-27: both have a 1M context and allow
    /// up to 393,216 output tokens. Per 1M at peak (the price the ledger
    /// uses): Flash $0.30 in / $1.20 out, V4 Pro $1.32 / $3.96.
    ///
    /// Flash is the default: a summary is a mid-difficulty task over a lot
    /// of tokens, and V4 Pro costs four times as much for it. V4 Pro stays
    /// for the hardest meetings.
    static let availableModels: [(id: String, label: String)] = [
        ("deepseek-flash",  String(localized: "DeepSeek Flash (recommended)")),
        ("deepseek-v4-pro", String(localized: "DeepSeek V4 Pro (hardest meetings, priciest)")),
    ]

    static let defaultModelID = "deepseek-flash"

    static let answerTokens = 8192

    /// Context window in tokens, nil for an id Daisy doesn't list.
    static func contextTokens(for model: String) -> Int? {
        switch model {
        case "deepseek-flash", "deepseek-v4-pro": 1_048_576
        default: nil
        }
    }

    static func plainName(for model: String) -> String {
        switch model {
        case "deepseek-flash": "DeepSeek Flash"
        case "deepseek-v4-pro": "DeepSeek V4 Pro"
        default: model
        }
    }

    /// Names DeepSeek has retired or folded in (updates, 2026-10-27):
    /// deepseek-chat and deepseek-reasoner were discontinued on
    /// 2026-07-24; deepseek-v4-flash is "still accepted" and served by
    /// V4.1 Flash, i.e. `deepseek-flash`. Exact match.
    static let retiredModels: [String: String] = [
        "deepseek-chat": "deepseek-flash",
        "deepseek-reasoner": "deepseek-flash",
        "deepseek-v4-flash": "deepseek-flash",
    ]

    static func resolvedModelID(_ stored: String) -> String {
        let id = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return defaultModelID }
        return retiredModels[id] ?? id
    }

    /// The stored model as Summarizer starts with it, written back when a
    /// retired name moved on — so the picker and the next launch agree.
    static func storedModelID(key: String, defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: key)
        let resolved = resolvedModelID(stored ?? defaultModelID)
        if let stored, stored != resolved {
            defaults.set(resolved, forKey: key)
        }
        return resolved
    }
}
