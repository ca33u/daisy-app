//
//  GigaChatAPISummarizer.swift
//  Daisy
//
//  SummaryProvider for GigaChat through cloud.ru Foundation Models — an
//  OpenAI-compatible Chat Completions endpoint on the person's own API
//  key (Keychain). Added 2026-10-27 (Egor, package G of the plan in the
//  vault, business/projects/daisy/2026-10-27-yandex-provider-plan.md §10,
//  §12a).
//
//  Why cloud.ru and not Sber's own API (Egor, 27.10: «давай Клаудру»):
//  Sber's API needs an OAuth token every 30 minutes and a TLS chain under
//  the Russian Trusted Root that macOS doesn't trust (a bundled root plus
//  an ATS exception), and its user agreement is for Russian residents and
//  forbids personal data in requests. cloud.ru takes a plain API key over
//  an ordinary public certificate (GlobalSign) — default trust, nothing
//  pinned, nothing loosened.
//
//  A separate file rather than a base URL on the OpenAI adapter, for the
//  reasons KimiAPISummarizer's header gives. cloud.ru's edges:
//
//   • `Authorization: Bearer <key>` (what the OpenAI SDK in its quickstart
//     sends; the gateway also names X-API-KEY). A bad key answers 400
//     «invalid api key secret», not 401 — probed 27.10 without a key.
//   • Model ids are `<owner>/<model>` (`GigaChat/GigaChat-3-Pro`).
//   • GigaChat-3-Pro doesn't reason (`GET /v1/models` marks `reasoning`
//     only on GigaChat 3.5 Reasoning), so there is nothing to switch off
//     and nothing reasoning-related is sent.
//   • The documented parameters are max_tokens, temperature, top_p and
//     the penalties; stream is OpenAI's. No temperature (the default
//     suits a summary), no response_format (the prompt asks for JSON and
//     `CloudSummaryDTO.decode` finds the object, as for Gemini). A 400
//     that refuses `stream_options` resends once without it, as YandexGPT.
//   • Errors are `{"code","message"}`, not OpenAI's `{"error":{…}}`.
//
//  The privacy wording is the same as for the other cloud providers — no
//  country (Egor, 27.10). cloud.ru is named only where the key is made.
//
//  Verified against cloud.ru/docs/foundation-models (quickstart, models),
//  the public /v1/models listing and the offer on 2026-10-27, without a key.
//

import Foundation
import os

nonisolated struct GigaChatAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .gigachat

    /// cloud.ru model id. See `availableModels`.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "GigaChatSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModelID : trimmed
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        if let key = apiKeyOverride ?? KeychainStore.get(account: SecretKey.gigachatAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.gigachatAPIKey),
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

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            // No reasoning on GigaChat-3-Pro: the budget is the summary
            // alone, what a long meeting's summary needed elsewhere
            // (8192, Kimi). cloud.ru publishes no per-model output cap.
            "max_tokens": Self.answerTokens,
            // Streamed: see CloudStreaming.
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        do {
            return try await send(body, apiKey: apiKey)
        } catch SummaryProviderError.httpError(_, 400, let message) where CloudStreaming.refusesStreamOptions(message) {
            // Without it the stream may carry no usage, and this
            // summary's spend goes unrecorded — said in the log, and
            // checked on a live key (plan step 0).
            log.warning("GigaChat refused stream_options — sending without it (no usage for this summary)")
            body["stream_options"] = nil
            return try await send(body, apiKey: apiKey)
        }
    }

    private func send(_ body: [String: Any], apiKey: String) async throws -> MeetingSummary {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total (streamed — see CloudStreaming).
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let text: String
        do {
            text = try await CloudStreaming.openAICompatibleText(
                request, session: urlSession, provider: Self.providerName, kind: .gigachat, model: model,
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

    static let providerName = "GigaChat"

    /// The HTTP failures a person can do something about, in words; the
    /// reasons follow «GigaChat: » (the case's own prefix). The bad-key
    /// body is from a probe; the balance and model ones are guessed at and
    /// checked on a live key (plan step 0).
    static func worded(status: Int, body: String, model: String) -> SummaryProviderError {
        let lowered = body.lowercased()
        if status == 400, CloudStreaming.refusesStreamOptions(body) {
            return .httpError(provider: providerName, status: status, body: body)
        }
        // Balance before key: a balance refusal may also mention the key.
        // Only money words — «insufficient permissions» is about the key.
        if status == 402 || (status == 403 && Self.namesEmptyBalance(lowered)) {
            return .modelUnavailable(provider: providerName, reason: String(localized: "the cloud.ru balance has run out. Top it up at console.cloud.ru and try again."))
        }
        if (400...403).contains(status), lowered.contains("api key") || lowered.contains("authorization") {
            return .modelUnavailable(provider: providerName, reason: String(localized: "the API key wasn’t accepted. Check it in \(SettingsRow.summaryProvider.path) — it’s the Key Secret shown once when the key was made, and the key needs the Foundation Models service."))
        }
        switch status {
        case 401, 403:
            return .modelUnavailable(provider: providerName, reason: String(localized: "the API key wasn’t accepted. Check it in \(SettingsRow.summaryProvider.path) — it’s the Key Secret shown once when the key was made, and the key needs the Foundation Models service."))
        case 429:
            return .modelUnavailable(provider: providerName, reason: String(localized: "too many requests. Try again in a minute."))
        case 404:
            return .modelUnavailable(provider: providerName, reason: String(localized: "no model \(model) — it may have been retired. Pick another model in \(SettingsRow.summaryProvider.path)."))
        default:
            return .httpError(provider: providerName, status: status, body: body)
        }
    }

    private static func namesEmptyBalance(_ lowered: String) -> Bool {
        ["insufficient balance", "insufficient funds", "insufficient_balance", "insufficient_funds",
         "баланс", "недостаточно средств"].contains { lowered.contains($0) }
    }

    // MARK: - Endpoint

    /// cloud.ru/docs/foundation-models/ug/topics/quickstart: base URL
    /// https://foundation-models.api.cloud.ru/v1.
    static let endpoint = URL(string: "https://foundation-models.api.cloud.ru/v1/chat/completions")!

    // MARK: - Catalog of model IDs offered in Settings

    /// One model (Egor's default, 27.10). From the public
    /// foundation-models.api.cloud.ru/v1/models, 2026-10-27: GigaChat-3-Pro
    /// has 262,144 tokens of context, structured output, and costs 73.03 ₽
    /// in / 176.39 ₽ out per 1M. GigaChat-2-Max is not offered: the older
    /// generation, half the context (131,072), 569.34 ₽ per 1M each way —
    /// about eight times the input price — and no structured output; it
    /// would only add a worse, dearer choice.
    static let availableModels: [(id: String, label: String)] = [
        // No «(recommended)»: there is nothing to recommend it over.
        ("GigaChat/GigaChat-3-Pro", "GigaChat-3-Pro"),
    ]

    static let defaultModelID = "GigaChat/GigaChat-3-Pro"

    static let answerTokens = 8192

    /// Context window in tokens (`max_model_len` in /v1/models), nil for an
    /// id Daisy doesn't list.
    static func contextTokens(for model: String) -> Int? {
        switch model {
        case "GigaChat/GigaChat-3-Pro": 262_144
        case "GigaChat/GigaChat-2-Max": 131_072
        default: nil
        }
    }

    /// The name without the owner prefix or the picker's hint.
    static func plainName(for model: String) -> String {
        String(model.split(separator: "/").last ?? Substring(model))
    }
}
