//
//  OpenAIAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that calls OpenAI's Chat Completions API in JSON
//  mode. User supplies their own API key (stored in Keychain).
//

import Foundation
import os

nonisolated struct OpenAIAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .openai

    /// Model identifier. See `availableModels` for the shipped list.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OpenAISummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.model = model
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        if let key = KeychainStore.get(account: SecretKey.openaiAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.openaiAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "OpenAI")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            // JSON mode — model is guaranteed to return parseable JSON.
            "response_format": ["type": "json_object"]
        ]
        // The GPT-5 generation speaks a different dialect of the same
        // endpoint: `max_tokens` is rejected in favour of
        // `max_completion_tokens`, and `temperature` only accepts its
        // default. Sending the old shape returns HTTP 400 "Unsupported
        // parameter", so branch instead of assuming.
        // Streamed (see CloudStreaming): the idle timeout no longer
        // races the whole generation, and the final chunk carries usage.
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        if Self.usesGPT5ParameterSet(model) {
            // This budget covers REASONING tokens as well as the visible
            // answer; a summary that spends its whole allowance thinking
            // comes back with empty content. Raised from 16 384 for
            // two-hour meetings — only generated tokens are billed.
            body["max_completion_tokens"] = 32_000
            // Chat completions streams nothing while the model reasons, so
            // a deep think is a long silent stretch on a long meeting (and
            // billed as output). A summary doesn't need more than low.
            if Self.takesLowReasoningEffort(model) { body["reasoning_effort"] = "low" }
        } else {
            // 16 384 (was 4096): a long meeting's summary in Russian or
            // German ran into the old ceiling. gpt-4o's own output limit.
            body["max_tokens"] = 16_384
            body["temperature"] = 0.4
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total: see CloudStreaming. Longer than Anthropic's:
        // it isn't documented whether chat completions sends keepalives
        // while a reasoning model thinks.
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Retries only before the answer starts — see CloudStreaming.
        let text = try await CloudStreaming.openAICompatibleText(
            request, session: urlSession, provider: "OpenAI", kind: .openai, model: model, log: log)

        do {
            let dto = try CloudSummaryDTO.decode(from: text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "OpenAI",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// Refreshed 2026-10-08 (developers.openai.com/api/docs/pricing).
    /// GPT-6 added: Astra $10/$50, 6.1 Sol $2/$10, Luna $0.10/$0.50 — all
    /// on chat completions, all taking `reasoning_effort: low` and
    /// `max_completion_tokens`. The 5.6 generation now: Sol $4/$20
    /// (promotional, through at least 2026-11-21), Terra $2/$12, Luna
    /// $0.20/$1.20; none is deprecated.
    ///
    /// 6.1 Sol is the default since 2026-10-10: it ran Daisy's summary
    /// request (json_object over a stream, reasoning_effort low) on a
    /// synthetic two-hour transcript — first byte and longest silence
    /// 3.1 s, finish `stop` (Benchmarks/stream_gaps.py) — and costs less
    /// than Terra ($2/$10 against $2/$12). A model someone picked stays.
    ///
    /// GPT-4o and GPT-4o mini stay on the list. They are not being shut
    /// down — they only fell out of the current price sheet — and mini
    /// at $0.15/$0.60 is an order of magnitude cheaper than anything in
    /// the 5.6 generation. Users on them are not migrated, so dropping
    /// them here would make the picker a one-way door: switch away once
    /// and there is no field to type the id back in.
    static let availableModels: [(id: String, label: String)] = [
        ("gpt-6.1-sol",   "GPT-6.1 Sol (recommended)"),
        ("gpt-6-astra",   "GPT-6 Astra (highest quality, priciest)"),
        ("gpt-6-luna",    "GPT-6 Luna (fastest, cheapest)"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-sol",   "GPT-5.6 Sol"),
        ("gpt-5.6-luna",  "GPT-5.6 Luna"),
        ("gpt-4o",        "GPT-4o (previous generation)"),
        ("gpt-4o-mini",   "GPT-4o mini (previous generation)"),
    ]

    static let defaultModelID = "gpt-6.1-sol"

    /// True for the GPT-5 generation and the o-series reasoning models,
    /// which take `max_completion_tokens` and refuse a custom
    /// `temperature`. Prefix-matched rather than an allow-list so a
    /// model released after this build still gets the right dialect —
    /// and so a user who types their own id into Settings isn't handed
    /// a 400 we could have avoided.
    /// Models that accept `reasoning_effort: "low"`. Not every reasoning
    /// id does: o1-mini and o1-preview take no effort at all, the -pro
    /// models only "high", and the -chat aliases don't reason — and a
    /// stale id kept from an older picker still reaches here.
    static func takesLowReasoningEffort(_ model: String) -> Bool {
        let id = model.lowercased()
        if id.contains("-pro") || id.contains("-chat") { return false }
        if id.hasPrefix("o1-mini") || id.hasPrefix("o1-preview") { return false }
        return id.hasPrefix("gpt-5") || id.hasPrefix("gpt-6")
            || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }

    static func usesGPT5ParameterSet(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5")
            || id.hasPrefix("gpt-6")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }
}
