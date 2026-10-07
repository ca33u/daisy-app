//
//  GeminiAPISummarizer.swift
//  Daisy
//
//  SummaryProvider for Google Gemini via its OpenAI-compatible Chat
//  Completions endpoint. User supplies their own API key from Google AI
//  Studio (stored in Keychain), same as Anthropic, OpenAI and Kimi.
//  Added 2026-10-07 at Egor's request.
//
//  A separate file rather than a base-URL parameter on the OpenAI
//  adapter, for the reasons KimiAPISummarizer's header gives: the
//  envelope is shared, the edges are not. Gemini's edges:
//
//   • Gemini 3 models think before answering. Google's guidance is to
//     leave `temperature` at its default for them (lowering it can make
//     the model loop), so none is sent; `reasoning_effort: low` keeps the
//     thinking — billed as output — proportionate to a summary.
//   • `max_tokens` maps to Gemini's output limit, which INCLUDES the
//     thinking tokens, so it is sized for both.
//   • No `response_format`: the prompt asks for JSON and
//     `CloudSummaryDTO.decode` already strips fences and finds the
//     outermost object, so the request leans on nothing Gemini-specific.
//   • Spend uses `geminiCompatible`: thinking tokens may sit outside
//     `completion_tokens`.
//   • Streamed with `stream_options.include_usage` (07.10.2026), so the
//     idle timeout no longer races the whole generation.
//
//  Privacy: a paid-tier key's data is not used to train Google's models;
//  a free-tier key's may be. That is Google's term, stated in the
//  Settings footer, not something Daisy can switch.
//
//  Verified against ai.google.dev/gemini-api/docs/openai, /models and
//  /pricing on 2026-10-07.
//

import Foundation
import os

nonisolated struct GeminiAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .gemini

    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "GeminiSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.model = model
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        if let key = KeychainStore.get(account: SecretKey.geminiAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.geminiAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "Gemini")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "reasoning_effort": "low",
            "max_tokens": 16_384,
            // Streamed: see CloudStreaming.
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total: Gemini thinks before it writes and says
        // nothing while it does.
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let text = try await CloudStreaming.openAICompatibleText(
            request, session: urlSession, provider: "Gemini", kind: .gemini, model: model, log: log, spend: TokenSpend.geminiCompatible(from:))

        do {
            let dto = try CloudSummaryDTO.decode(from: text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "Gemini",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Endpoint

    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!

    // MARK: - Catalog of model IDs offered in Settings

    /// From ai.google.dev/gemini-api/docs/models, 2026-10-07. Prices per
    /// MTok in/out: 3.8 Flash $0.75/$3.75 until 31.12.2026, then
    /// $1.50/$7.50; 3.5 Flash-Lite $0.30/$2.50; 3.1 Pro (preview)
    /// $2/$12 up to 200K tokens.
    ///
    /// 3.8 Flash is the default: it is Google's own recommendation and a
    /// stable model. Pro is preview, so it may change or go away; it is
    /// offered for the hardest meetings, not as a default.
    static let availableModels: [(id: String, label: String)] = [
        ("gemini-3.8-flash",       String(localized: "Gemini 3.8 Flash (recommended)")),
        ("gemini-3.5-flash-lite",  String(localized: "Gemini 3.5 Flash-Lite (cheapest)")),
        ("gemini-3.1-pro-preview", String(localized: "Gemini 3.1 Pro (preview, priciest)")),
    ]

    static let defaultModelID = "gemini-3.8-flash"
}
