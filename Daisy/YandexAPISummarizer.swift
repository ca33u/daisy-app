//
//  YandexAPISummarizer.swift
//  Daisy
//
//  SummaryProvider for YandexGPT — Yandex AI Studio's OpenAI-compatible
//  Chat Completions endpoint, on the user's own API key (Keychain) and
//  folder ID. Added 2026-10-27 for Russian-speaking users (Egor); plan in
//  the vault, business/projects/daisy/2026-10-27-yandex-provider-plan.md.
//
//  A separate file rather than a base URL on the OpenAI adapter, for the
//  reasons KimiAPISummarizer's header gives. Yandex's edges:
//
//   • Two strings, not one: the key goes in `Authorization: Api-Key …`
//     (not Bearer — the documented header for an API key), and the
//     folder ID both in the model URI (`gpt://<folder>/<model>`) and in
//     `OpenAI-Project`, as Yandex's own examples send it.
//   • `x-data-logging-enabled: false` on every request. Yandex logs
//     request data by default; with this header off, its docs say the
//     requests "will not be used to improve AI Studio". Not a setting:
//     there is no reason anyone would want their meetings logged.
//   • Models are retired on a date and the old URI then answers 400 —
//     no fallback. Ids are explicit, a stored retired id is moved to its
//     successor at launch (`resolvedModelID`), and a 400 that names the
//     model says so in words.
//   • The documented parameter set is temperature, max_tokens, stream and
//     response_format; nothing else is sent. No temperature (Yandex's
//     default 0.3 suits a summary), no response_format (the prompt asks
//     for JSON and `CloudSummaryDTO.decode` finds the object, as for
//     Gemini). `stream_options.include_usage` is OpenAI's standard way
//     to get usage at the end of a stream; if this endpoint refuses it by
//     name, the request goes once more without it.
//   • Reasoning. Yandex: reasoning is on by default where a model has it;
//     Qwen "allows you to turn off reasoning but not to choose its depth",
//     and the documented `reasoning_effort` values (low/medium/high) have
//     no "off". How to turn it off for Qwen, and whether Alice or
//     DeepSeek think at all here, is not documented — so nothing is sent
//     that could turn every summary into a 400, and the answer budget is
//     sized for thinking plus the summary. Step 0 of the plan (a live
//     key) settles it.
//   • One synchronous request runs at most 15 minutes, and an account
//     without a subscription runs two at a time (concepts/limits).
//
//  The privacy wording is the same as for the other cloud providers — no
//  country (Egor, 27.10).
//
//  Verified against aistudio.yandex.ru/docs (quickstart, concepts/api,
//  concepts/generation/models, chain-of-thought, operations/disable-logging,
//  pricing) on 2026-10-27, without a key.
//

import Foundation
import os

nonisolated struct YandexAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .yandex

    /// The model's suffix in `gpt://<folder>/<model>`. See `availableModels`.
    let model: String
    /// As typed in Settings; `normalizedFolderID` cleans it.
    let folderID: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "YandexSummarizer")

    /// Tests only: a key that bypasses the Keychain.
    let apiKeyOverride: String?

    init(model: String = defaultModelID, folderID: String, urlSession: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.model = Self.resolvedModelID(model)
        self.folderID = folderID
        self.urlSession = urlSession
        self.apiKeyOverride = apiKeyOverride
    }

    func isReady() async -> Bool {
        guard Self.normalizedFolderID(folderID) != nil else { return false }
        if let key = apiKeyOverride ?? KeychainStore.get(account: SecretKey.yandexAPIKey), !key.isEmpty {
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
        guard let apiKey = apiKeyOverride ?? KeychainStore.get(account: SecretKey.yandexAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: Self.providerName)
        }
        guard let folder = Self.normalizedFolderID(folderID) else {
            throw SummaryProviderError.modelUnavailable(
                provider: Self.providerName,
                reason: String(localized: "a folder ID is needed too. Copy it from the folder name at the top of AI Studio and paste it in \(SettingsRow.summaryProvider.path)."))
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        // Refuse before paying for a 400: the context window is the
        // prompt AND the answer, so the room for the meeting is the window
        // less the answer budget.
        let answerTokens = Self.answerTokens(for: model)
        if let window = Self.contextTokens(for: model) {
            let approx = LocalContextGuard.estimatedTokens(promptChars: systemPrompt.count + userPrompt.count)
            let room = window - answerTokens
            if approx > room {
                let name = Self.plainName(for: model)
                let reason = Self.baseID(model) == Self.longestModelID
                    ? String(localized: "this meeting is longer than \(name) can read (about \(approx) tokens of \(room)).")
                    : String(localized: "this meeting is longer than \(name) can read (about \(approx) tokens of \(room)). Pick DeepSeek V4.1 Flash in \(SettingsRow.summaryProvider.path).")
                throw SummaryProviderError.modelUnavailable(provider: Self.providerName, reason: reason)
            }
        }

        var body: [String: Any] = [
            "model": "gpt://\(folder)/\(model)",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "max_tokens": answerTokens,
            // Streamed: see CloudStreaming.
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        do {
            return try await send(body, apiKey: apiKey, folder: folder)
        } catch SummaryProviderError.httpError(_, 400, let message) where Self.refusesStreamOptions(message) {
            // Without it the stream may carry no usage, and this
            // summary's spend goes unrecorded — said in the log, and
            // checked on a live key (plan step 0).
            log.warning("YandexGPT refused stream_options — sending without it (no usage for this summary)")
            body["stream_options"] = nil
            return try await send(body, apiKey: apiKey, folder: folder)
        }
    }

    private func send(_ body: [String: Any], apiKey: String, folder: String) async throws -> MeetingSummary {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Api-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(folder, forHTTPHeaderField: "OpenAI-Project")
        request.setValue("false", forHTTPHeaderField: "x-data-logging-enabled")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Idle, not total (streamed — see CloudStreaming): a model that
        // reasons can say nothing for a while. Yandex itself stops a
        // synchronous request at 15 minutes.
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let text: String
        do {
            // geminiCompatible: the largest reading of the output side,
            // so reasoning tokens outside completion_tokens still count.
            text = try await CloudStreaming.openAICompatibleText(
                request, session: urlSession, provider: Self.providerName, kind: .yandex, model: model,
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

    static let providerName = "YandexGPT"

    static var missingFolderMessage: String {
        String(localized: "YandexGPT also needs a folder ID. Copy it from the folder name at the top of AI Studio and paste it in \(SettingsRow.summaryProvider.path).")
    }

    /// The HTTP failures a person can do something about, in words. The
    /// rest keep the status and body. The bodies are guessed at from the
    /// OpenAI-shaped errors this endpoint returns; step 0 of the plan
    /// checks them against a live key.
    static func worded(status: Int, body: String, model: String) -> SummaryProviderError {
        let lowered = body.lowercased()
        // Left as it came: `summarize` drops the parameter and retries.
        if status == 400, refusesStreamOptions(body) {
            return .httpError(provider: providerName, status: status, body: body)
        }
        // The reasons follow «YandexGPT: » (the case's own prefix).
        switch status {
        case 401, 403:
            return .modelUnavailable(provider: providerName, reason: String(localized: "the API key or the folder ID wasn’t accepted. Check both in \(SettingsRow.summaryProvider.path)."))
        case 429:
            return .modelUnavailable(provider: providerName, reason: String(localized: "too many requests — an account without a subscription runs two at a time. Try again in a minute."))
        case 400 where namesMissingModel(lowered), 404 where namesMissingModel(lowered):
            return .modelUnavailable(provider: providerName, reason: String(localized: "no model \(model) for this folder — Yandex may have retired it. Pick another model in \(SettingsRow.summaryProvider.path)."))
        default:
            return .httpError(provider: providerName, status: status, body: body)
        }
    }

    /// A 400 that refuses `stream_options` — by its name, by the field
    /// inside it, or with the underscore dropped. One check, lowercased,
    /// for both the retry and the wording.
    static func refusesStreamOptions(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return ["stream_options", "streamoptions", "include_usage"].contains { lowered.contains($0) }
    }

    /// A 400 about the model itself, not about a limit that mentions the
    /// model («max_tokens exceeds the model's limit» is not a retirement).
    private static func namesMissingModel(_ lowered: String) -> Bool {
        lowered.contains("model_uri") || lowered.contains("model uri")
            || (lowered.contains("model") && ["not found", "does not exist", "unknown", "deprecated", "retired"]
                .contains { lowered.contains($0) })
    }

    // MARK: - Endpoint

    /// «All services are available at https://ai.api.cloud.yandex.net/v1»
    /// (concepts/api). The older llm.api.cloud.yandex.net/v1 answers too.
    static let endpoint = URL(string: "https://ai.api.cloud.yandex.net/v1/chat/completions")!

    /// The folder ID as Yandex wants it, or nil. Accepts a whole
    /// `gpt://<folder>/<model>` URI pasted from the docs or the console.
    static func normalizedFolderID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("gpt://") {
            value = String(value.dropFirst("gpt://".count).prefix { $0 != "/" })
        }
        // ASCII only: a Cyrillic look-alike typed on the Russian layout
        // («с», «о», «е») would pass `isLetter` and fail at Yandex.
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return value
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// Egor, 27.10. From concepts/generation/models and pricing,
    /// 2026-10-27 (USD per 1K without VAT, the non-resident price list —
    /// the token ledger counts dollars): Alice AI LLM 128K, $0.0041/$0.0098;
    /// Qwen3.6 35B A3B 256K, $0.0016/$0.0025; DeepSeek V4.1 Flash 1M,
    /// $0.0025/$0.0041 (cached $0.0006). Not offered: YandexGPT Pro 5.1
    /// (32K — about an hour and a half of Russian speech) and Alice AI
    /// LLM Flash.
    static let availableModels: [(id: String, label: String)] = [
        ("aliceai-llm",         String(localized: "Alice AI LLM (recommended)")),
        ("qwen3.6-35b-a3b",     String(localized: "Qwen3.6 35B (long meetings)")),
        ("deepseek-v4.1-flash", String(localized: "DeepSeek V4.1 Flash (very long meetings)")),
    ]

    static let defaultModelID = "aliceai-llm"

    /// The model to suggest when a meeting doesn't fit.
    static let longestModelID = "deepseek-v4.1-flash"

    /// The model's name without the picker's hint («(recommended)»).
    static func plainName(for model: String) -> String {
        switch baseID(model) {
        case "aliceai-llm": "Alice AI LLM"
        case "qwen3.6-35b-a3b": "Qwen3.6 35B"
        case "deepseek-v4.1-flash": "DeepSeek V4.1 Flash"
        default: model
        }
    }

    /// Context window in tokens (concepts/generation/models), nil for an
    /// id Daisy doesn't list — no guess, no refusal.
    static func contextTokens(for model: String) -> Int? {
        switch baseID(model) {
        case "aliceai-llm": 131_072
        case "qwen3.6-35b-a3b": 262_144
        case "deepseek-v4.1-flash": 1_048_576
        default: nil
        }
    }

    /// `max_tokens`. Qwen and DeepSeek may reason before the summary and
    /// the budget covers both; Alice gets what a long meeting's summary
    /// needed elsewhere (8192, Kimi). Yandex publishes no per-model
    /// output cap — step 0.
    static func answerTokens(for model: String) -> Int {
        baseID(model) == "aliceai-llm" ? 8192 : 16_384
    }

    /// Ids Yandex switches off, and what each becomes. Only ones that are
    /// really going away (concepts/generation/models, 2026-10-27): gpt-oss
    /// until 30.10.2026, YandexGPT Lite 5 and DeepSeek V4 Flash until
    /// 15.11.2026. Exact match — a hand-typed id stays the person's.
    static let retiredModels: [String: String] = [
        "gpt-oss-120b": "aliceai-llm",
        "gpt-oss-20b": "aliceai-llm",
        "yandexgpt-5-lite": "aliceai-llm",
        "deepseek-v4-flash": "deepseek-v4.1-flash",
    ]

    /// The stored model as Summarizer starts with it, written back when a
    /// retired id moved on — so the picker and the next launch agree.
    static func storedModelID(key: String, defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: key)
        let resolved = resolvedModelID(stored ?? defaultModelID)
        if let stored, stored != resolved {
            defaults.set(resolved, forKey: key)
        }
        return resolved
    }

    /// The model without a version branch: Yandex's URIs can end in
    /// `/latest` or `/rc` (`aliceai-llm/latest`), and the window, the
    /// price and a retirement belong to the model, not to the branch.
    static func baseID(_ model: String) -> String {
        String(model.prefix { $0 != "/" })
    }

    /// A stored or typed model as the request should carry it: the
    /// suffix of a whole `gpt://<folder>/<model>` URI, moved past any
    /// retired id — a retired model's `/latest` goes with it.
    static func resolvedModelID(_ stored: String) -> String {
        var id = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("gpt://") {
            id = id.dropFirst("gpt://".count).split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        }
        if id.isEmpty { return defaultModelID }
        // A fine-tune (`<base>/latest@<suffix>`) is the person's own
        // model: never swapped for a stock successor.
        if id.contains("@") { return id }
        return retiredModels[baseID(id)] ?? id
    }
}
