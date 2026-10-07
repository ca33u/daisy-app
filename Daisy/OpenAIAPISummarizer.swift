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
        let bytes = try await CloudStreaming.open(request, session: urlSession, provider: "OpenAI", log: log)
        var stream = OpenAIStreamAccumulator()
        do {
            try await CloudStreaming.forEachData(in: bytes) { stream.consume($0) }
        } catch {
            TokenLedgerSink.record(provider: .openai, model: model, spend: .openAICompatible(from: stream.completionJSON))
            log.error("OpenAI stream broke off: \(error.localizedDescription, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: "OpenAI", message: error.localizedDescription)
        }

        // Usage is billable even if the response later proves unusable,
        // so record it before the checks.
        TokenLedgerSink.record(provider: .openai, model: model, spend: .openAICompatible(from: stream.completionJSON))

        if let message = stream.streamError {
            log.error("OpenAI stream error: \(message, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: "OpenAI", message: message)
        }
        switch stream.finishReason {
        case "length":
            throw SummaryProviderError.outputTruncated(provider: "OpenAI")
        case "content_filter":
            throw SummaryProviderError.refused(provider: "OpenAI")
        default:
            break
        }
        guard !stream.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("OpenAI reply had no content (finish: \(stream.finishReason ?? "none", privacy: .public))")
            throw SummaryProviderError.invalidResponse(provider: "OpenAI")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: stream.text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "OpenAI",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// Refreshed 2026-07-28. `gpt-4-turbo` is gone from the list because
    /// it is deprecated with a 2026-10-23 shutdown (`gpt-5` /
    /// `gpt-5-mini` follow on 2026-12-11).
    /// Prices per MTok in/out: Sol $5/$30, Terra $2.50/$15, Luna $1/$6.
    /// Terra leads because a meeting summary is a mid-difficulty job on
    /// a lot of tokens — Sol's headroom rarely shows up in the output
    /// and always shows up on the bill.
    ///
    /// GPT-4o and GPT-4o mini stay on the list. They are not being shut
    /// down — they only fell out of the current price sheet — and mini
    /// at $0.15/$0.60 is an order of magnitude cheaper than anything in
    /// the 5.6 generation. Users on them are not migrated, so dropping
    /// them here would make the picker a one-way door: switch away once
    /// and there is no field to type the id back in.
    static let availableModels: [(id: String, label: String)] = [
        ("gpt-5.6-terra", "GPT-5.6 Terra (recommended)"),
        ("gpt-5.6-sol",   "GPT-5.6 Sol (highest quality, slower)"),
        ("gpt-5.6-luna",  "GPT-5.6 Luna (fastest, cheapest)"),
        ("gpt-4o",        "GPT-4o (previous generation)"),
        ("gpt-4o-mini",   "GPT-4o mini (previous generation, cheapest)"),
    ]

    static let defaultModelID = "gpt-5.6-terra"

    /// True for the GPT-5 generation and the o-series reasoning models,
    /// which take `max_completion_tokens` and refuse a custom
    /// `temperature`. Prefix-matched rather than an allow-list so a
    /// model released after this build still gets the right dialect —
    /// and so a user who types their own id into Settings isn't handed
    /// a 400 we could have avoided.
    static func usesGPT5ParameterSet(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }
}
