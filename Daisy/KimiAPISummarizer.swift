//
//  KimiAPISummarizer.swift
//  Daisy
//
//  SummaryProvider for Kimi (Moonshot AI) via its OpenAI-compatible
//  Chat Completions endpoint. User supplies their own API key (stored
//  in Keychain), same as Anthropic and OpenAI.
//
//  WHY A SEPARATE FILE RATHER THAN A BASE-URL PARAMETER ON THE OPENAI
//  ADAPTER. "OpenAI-compatible" is true of the request envelope and
//  false of everything that matters at the edges: the parameter set
//  differs per model generation on BOTH sides, the errors differ, the
//  model catalogue and prices are Moonshot's, and the privacy story is
//  materially different (see below). LM Studio already went down the
//  shared-adapter road and ended up a near-copy anyway. A copy that
//  states its own quirks beats a parameterised adapter whose branches
//  are all "if it's the other one".
//
//  THE PRIVACY LINE, WHICH IS NOT LIKE THE OTHER CLOUD PROVIDERS.
//  Moonshot's own documentation says requests to the international
//  endpoint (api.moonshot.ai) are processed in China. For an app that
//  sells "your meetings stay yours", that cannot be buried — it is in
//  `privacyTag` and in the Settings footer, in those words. Users who
//  need EU/US data residency should read that and pick something else;
//  users who don't get a very cheap, very large-context provider.
//
//  Verified against platform.kimi.ai/docs/api/chat on 2026-07-31.
//

import Foundation
import os

nonisolated struct KimiAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .kimi

    /// Model identifier. See `availableModels` for the shipped list.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "KimiSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.model = model
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        if let key = KeychainStore.get(account: SecretKey.kimiAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.kimiAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "Kimi")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            // Documented as supported on this endpoint. Unlike LM Studio,
            // where the same key had to be REMOVED because the server
            // answered with an empty completion (GitHub #5).
            "response_format": ["type": "json_object"],
            // Streamed (07.10.2026): no idle timeout racing a long answer,
            // and the last chunk carries usage.
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        if Self.isThinkingModel(model) {
            // K3 reasons before it answers and cannot be told not to, so
            // the budget has to cover thinking as well as the summary —
            // same shape as the GPT-5 branch in the OpenAI adapter.
            //
            // And it is CAPPED rather than left at the default 131,072,
            // because Moonshot bills rate-limit consumption as request
            // tokens PLUS max_completion_tokens, whatever the model
            // actually generates. Leaving the default in place would
            // spend a user's whole per-minute allowance on one meeting.
            body["max_completion_tokens"] = 16_384
        } else {
            // 8192 (was 4096): a long meeting's summary hit the old cap.
            // Kept modest — Moonshot counts max tokens against the rate
            // limit whether or not they're generated (see above).
            body["max_tokens"] = 8192
            body["temperature"] = 0.4
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total (streamed — see CloudStreaming): K3 thinks
        // before it writes and says nothing while it does.
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let text = try await CloudStreaming.openAICompatibleText(
            request, session: urlSession, provider: "Kimi", kind: .kimi, model: model, log: log)

        do {
            let dto = try CloudSummaryDTO.decode(from: text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "Kimi",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Endpoint

    /// International endpoint. There is also `api.moonshot.cn` for
    /// mainland accounts; it is not offered because a key issued on one
    /// platform does not work on the other, and a picker that lets you
    /// choose the wrong one just produces 401s.
    static let endpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!

    /// K3 reasons before answering and the thinking cannot be switched
    /// off, which changes both the parameter set and the bill — its
    /// output price covers tokens the user never reads.
    static func isThinkingModel(_ model: String) -> Bool {
        model.lowercased().hasPrefix("kimi-k3")
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// From platform.kimi.ai/docs/api/chat, 2026-07-31. Prices per MTok
    /// in/out: K3 $3/$15, K2.6 $0.95/$4, K2.7 Code $0.95/$4.
    ///
    /// K2.6 is the default, not K3, and the reason is the job rather
    /// than the leaderboard: a meeting summary is a mid-difficulty task
    /// over a lot of tokens. K3's reasoning rarely shows up in the
    /// output and always shows up on the bill — four times the input
    /// price, nearly four times the output, plus thinking tokens that
    /// cannot be turned off.
    ///
    /// K2.7 Code is here because it is the same price as K2.6 and some
    /// users' meetings ARE code review; it is not recommended for
    /// general use.
    static let availableModels: [(id: String, label: String)] = [
        ("kimi-k2.6",      String(localized: "Kimi K2.6 (recommended)")),
        ("kimi-k3",        String(localized: "Kimi K3 (reasoning, priciest)")),
        ("kimi-k2.7-code", String(localized: "Kimi K2.7 Code (technical meetings)")),
    ]

    static let defaultModelID = "kimi-k2.6"
}
