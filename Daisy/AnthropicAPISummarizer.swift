//
//  AnthropicAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that calls Anthropic's Messages API. User supplies
//  their own API key (stored in Keychain). The transcript is sent only
//  to api.anthropic.com over HTTPS.
//

import Foundation
import os

nonisolated struct AnthropicAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .anthropic

    /// Model identifier. Defaults to Sonnet 5 — strong quality/cost.
    let model: String
    /// Override for testing; production passes URLSession.shared.
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AnthropicSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.model = model
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        if let key = KeychainStore.get(account: SecretKey.anthropicAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.anthropicAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "Anthropic")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        var body: [String: Any] = [
            "model": model,
            // Room for thinking AND the answer. Claude 5 models think by
            // default (no `thinking` param needed), and on a two-hour
            // meeting thinking used the whole old 4096 allowance — the
            // reply came back with a thinking block and no text (log
            // report 07.10.2026). Only generated tokens are billed, so a
            // high ceiling costs nothing on a short meeting; streaming is
            // what makes a ceiling this high safe from HTTP timeouts.
            "max_tokens": Self.maxOutputTokens(for: model),
            "stream": true,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        // A summary is mid-difficulty work over many tokens: medium effort
        // keeps the thinking proportionate. Haiku 4.5 rejects `effort`.
        if Self.acceptsEffort(model) {
            body["output_config"] = ["effort": "medium"]
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Idle, not total: see CloudStreaming.
        request.timeoutInterval = CloudStreaming.idleTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Retries (429 / 5xx / a connection that never opened) happen only
        // before the answer starts — see CloudStreaming.
        let bytes = try await CloudStreaming.open(request, session: urlSession, provider: "Anthropic", log: log)
        var stream = AnthropicStreamAccumulator()
        do {
            try await CloudStreaming.forEachData(in: bytes) { stream.consume($0) }
        } catch {
            // Bill what was generated before the break, then report it.
            TokenLedgerSink.recordAnthropic(model: model, json: stream.messageJSON)
            log.error("Anthropic stream broke off: \(error.localizedDescription, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: "Anthropic", message: error.localizedDescription)
        }

        // Usage is billed even when the content proves unusable, so record
        // it before the checks below.
        TokenLedgerSink.recordAnthropic(model: model, json: stream.messageJSON)

        if let message = stream.streamError {
            log.error("Anthropic stream error event: \(message, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: "Anthropic", message: message)
        }
        switch stream.stopReason {
        case "max_tokens":
            log.error("Anthropic reply hit max_tokens (blocks: \(stream.blockTypes.joined(separator: ","), privacy: .public))")
            throw SummaryProviderError.outputTruncated(provider: "Anthropic")
        case "refusal":
            throw SummaryProviderError.refused(provider: "Anthropic")
        default:
            break
        }

        // Every TEXT block, joined — thinking blocks come first and carry
        // no answer (1.0.7.51: reading only the first block reported a
        // perfectly good reply as "unexpected response").
        let text = stream.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No text at all: log why, since the block types are the whole
            // diagnosis and they carry no user content.
            log.error("Anthropic reply had no text block (types: \(stream.blockTypes.joined(separator: ","), privacy: .public), stop: \(stream.stopReason ?? "none", privacy: .public))")
            throw SummaryProviderError.invalidResponse(provider: "Anthropic")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "Anthropic",
                message: error.localizedDescription
            )
        }
    }

    /// The generations known to take a 64K ceiling and `effort`: the
    /// Claude 5 family and 4.6–4.8. An allow-list, because Settings keeps
    /// a typed-in id as "Custom" — an older model would 400 on `effort`
    /// and on a ceiling above its own (review find, 07.10.2026).
    private static let modernPrefixes = [
        "claude-sonnet-5", "claude-opus-5", "claude-fable-5", "claude-mythos-5",
        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6",
    ]

    private static func isModern(_ model: String) -> Bool {
        let id = model.lowercased()
        return modernPrefixes.contains { id.hasPrefix($0) }
    }

    /// Output ceiling: 64K on the modern models (they allow 128K), 32K on
    /// Haiku 4.5, and the old 4096 on anything else.
    static func maxOutputTokens(for model: String) -> Int {
        if isModern(model) { return 64_000 }
        if model.lowercased().hasPrefix("claude-haiku-4-5") { return 32_000 }
        return 4096
    }

    /// `output_config.effort`: the modern models only — Haiku 4.5 and
    /// older reject it.
    static func acceptsEffort(_ model: String) -> Bool { isModern(model) }

    // MARK: - Catalog of model IDs offered in Settings

    /// Refreshed 2026-07-28. Four rungs, cheapest-capable first:
    /// Sonnet is the one to use, Opus when the meeting is dense, Fable
    /// when nothing else will do, Haiku when volume matters more than
    /// nuance. Prices per MTok in/out at the time of writing: Sonnet 5
    /// $2/$10 (introductory, $3/$15 from 1 Sep 2026), Opus 5 $5/$25,
    /// Fable 5 $10/$50, Haiku 4.5 $1/$5.
    ///
    /// From the 4.6 generation on, a DATELESS Anthropic id is a pinned
    /// snapshot rather than a moving pointer, so `claude-sonnet-5` is
    /// safe to ship — it won't silently become a different model.
    /// Haiku keeps its dated id because that generation predates the
    /// change.
    static let availableModels: [(id: String, label: String)] = [
        ("claude-sonnet-5", "Claude Sonnet 5 (recommended)"),
        ("claude-opus-5",   "Claude Opus 5 (highest quality, slower)"),
        ("claude-fable-5",  "Claude Fable 5 (most capable, priciest)"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (fastest, cheapest)"),
    ]

    static let defaultModelID = "claude-sonnet-5"
    // 2026-05-27 — retry/backoff helpers lifted out into
    // `CloudHTTPRetry.fetch(request:session:log:)`. Shared between
    // Anthropic + OpenAI providers and any future cloud-LLM path.
}
