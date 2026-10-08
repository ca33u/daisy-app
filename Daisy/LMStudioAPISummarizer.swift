//
//  LMStudioAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that talks to a locally-running LM Studio
//  (https://lmstudio.ai) via its OpenAI-compatible
//  `/v1/chat/completions` REST endpoint. No API key required — LM Studio
//  binds to 127.0.0.1:1234 by default and accepts unauthenticated requests.
//  Data never leaves the Mac.
//
//  Why this exists as a first-class provider (build 40):
//  Pre-build-40 the "LM Studio" option in Settings → Summary Provider
//  routed through `MCPSummarizer` with a preset baseURL and a JSON
//  arguments template that assumed an MCP+SSE shim was running. But
//  LM Studio does NOT speak MCP — it speaks OpenAI-compatible REST.
//  Picking "LM Studio" without first wiring up an MCP shim caused
//  every summary to fail with a cryptic SSE handshake error. The
//  pre-PH audit (2026-05-28) flagged this as a P0 blocker.
//
//  This adapter posts to `/v1/chat/completions` directly — the request
//  shape is identical to OpenAIAPISummarizer except for the base URL
//  and the absence of Authorization header. Probe via `/v1/models`.
//

import Foundation
import os

nonisolated struct LMStudioAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .lmStudio

    /// Base URL of the LM Studio server. Default: `http://127.0.0.1:1234`.
    let baseURL: URL

    /// LM Studio model identifier. Must already be loaded in the
    /// LM Studio UI (the user picks the model from LM Studio's
    /// model picker; this string matches what the server reports
    /// via `/v1/models`).
    let model: String

    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LMStudioSummarizer")

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:1234")!,
        model: String = defaultModelID,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.urlSession = urlSession
    }

    /// "Is LM Studio's server actually running with a model loaded?"
    /// probe via `/v1/models`. Returns false on any network error or
    /// non-2xx status. If the LM Studio app is running but no model
    /// is loaded, `/v1/models` returns 200 with an empty list — we
    /// still consider that "reachable", and let the actual summarize
    /// surface the no-model-loaded error if/when the user records.
    func isReady() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
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

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        // Request shape identical to OpenAI's chat.completions —
        // LM Studio's local server is API-compatible.
        // NOTE — deliberately NO `response_format`. LM Studio's newer
        // server builds reject `{"type":"json_object"}` outright with
        // HTTP 400 (`'response_format.type' must be 'json_schema' or
        // 'text'`) — the OpenAI-style json_object mode simply isn't a
        // valid value there (GitHub #5). Rather than pin a brittle,
        // version-specific `json_schema` (unsupported on older builds),
        // we rely entirely on the prompt's JSON instructions plus the
        // tolerant `CloudSummaryDTO.decode` (fence-stripping + balanced-
        // brace extraction + alias retry), which is what actually parses
        // every local provider's output anyway.
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "max_tokens": 4096,
            "temperature": 0.4,
            "stream": false
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same 180s timeout as Ollama — local 7B models on M-series
        // hardware can take 30-60s for long transcripts.
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SummaryProviderError.modelUnavailable(
                provider: "LM Studio",
                reason: "Couldn't reach LM Studio at \(baseURL.absoluteString). Open the LM Studio app, load a model, and start the server (Developer tab → Start). (\(error.localizedDescription))"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: "LM Studio")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? "<empty>"
            log.error("LM Studio HTTP \(http.statusCode): \(bodyString, privacy: .private)")
            throw SummaryProviderError.httpError(
                provider: "LM Studio",
                status: http.statusCode,
                body: bodyString
            )
        }

        // Response shape (OpenAI-compatible):
        // { "choices": [{ "message": { "content": "<JSON>" }, ... }], ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.invalidResponse(provider: "LM Studio")
        }

        // Keep the volume counter honest even when the local server's
        // content shape is malformed.
        TokenLedgerSink.record(
            provider: .lmStudio,
            model: model,
            spend: .openAICompatible(from: json)
        )

        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: "LM Studio")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: content)
            return dto.toMeetingSummary()
        } catch {
            // Before blaming the JSON: LM Studio pins the context window
            // when the model is LOADED, and there is no per-request knob
            // to widen it the way Ollama's `num_ctx` allows. An hour of
            // speech is 20-30k tokens against a stock 4096, so the server
            // trims — from the top, taking the system prompt and its
            // schema with it. What comes back is a model improvising on a
            // bare transcript, and "couldn't parse JSON" sends the user
            // hunting for the wrong bug (Ken, 2026-07-28: he concluded
            // screenshots were filling the context, when the screen text
            // is capped at 5000 characters and the speech was the load).
            //
            // Raw `prompt_tokens`, not the ledger's cache-adjusted
            // figure: this is a size comparison, and a missing or zero
            // count has to read as "the server didn't say" rather than
            // "the server read nothing".
            let reported = LocalContextGuard.positive(
                (json["usage"] as? [String: Any])?["prompt_tokens"]
            )
            let estimated = LocalContextGuard.estimatedTokens(
                promptChars: systemPrompt.count + userPrompt.count
            )
            // Meetings only. The same `summarize` also serves the
            // pre-meeting brief, the voice profile, dictation polish and
            // the transcript second pass, whose inputs are dossiers,
            // corpora and small transcript chunks — "this transcript"
            // and "meetings this long" would be lies there, and a
            // confidently wrong diagnosis is worse than the generic
            // parse error. (The second pass in particular chunks to
            // ~2.5k characters precisely so it can't overflow, and
            // swallows its own errors on the way out.)
            if case .meeting = task, LocalContextGuard.truncationSuspected(
                estimatedTokens: estimated,
                reportedPromptTokens: reported,
                windowTokens: LocalContextGuard.stockLocalContextTokens
            ) {
                log.error("LM Studio context overflow: est ~\(estimated) tokens, server read \(reported ?? -1)")
                throw SummaryProviderError.contextOverflow(
                    provider: "LM Studio",
                    approxPromptTokens: estimated,
                    reportedPromptTokens: reported
                )
            }
            throw SummaryProviderError.parseFailed(
                provider: "LM Studio",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog

    /// Default model id. LM Studio model IDs depend on what the
    /// user has downloaded — there's no universal name, and the
    /// identifier format has drifted between LM Studio versions
    /// (`qwen2.5-7b-instruct` then, `qwen/qwen3.5-4b` now). So this is a
    /// starting guess only; the picker below reads the running
    /// server's `/v1/models` and the user can type an id by hand. If
    /// the id mismatches what's loaded, LM Studio returns 404.
    static let defaultModelID = "qwen/qwen3.5-4b"

    /// Default base URL. Stock LM Studio binds here when its local
    /// server is started.
    static let defaultBaseURLString = "http://127.0.0.1:1234"

    /// Catalog of commonly-loaded LM Studio model IDs. Strictly a
    /// hint, and the weakest of the three sources the picker has:
    /// `fetchLoadedModels` (what the server actually reports) beats it,
    /// and the user's own typing beats everything. Refreshed
    /// 2026-07-28 to the current generation and the publisher/model id
    /// form LM Studio shows under "API Identifier". Gemma 4 added
    /// 2026-10-08 (lmstudio.ai/models/gemma-4).
    static let availableModels: [(id: String, label: String)] = [
        ("qwen/qwen3.5-4b",   "Qwen 3.5 4B — multilingual, recommended"),
        ("qwen/qwen3.5-9b",   "Qwen 3.5 9B — multilingual, more capable"),
        ("google/gemma-4-e4b", "Gemma 4 E4B — multilingual"),
        ("google/gemma-4-12b", "Gemma 4 12B — more capable"),
        ("google/gemma-3-4b", "Gemma 3 4B — older, fast"),
        ("google/gemma-3-12b", "Gemma 3 12B — older"),
        ("openai/gpt-oss-20b", "GPT-OSS 20B"),
    ]

    // MARK: - Loaded-model listing

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    /// The models the running LM Studio server reports via `/v1/models`
    /// — the same endpoint `isReady()` probes, here read for its
    /// payload. Mirrors `OllamaAPISummarizer.fetchInstalledModels`, and
    /// exists for the same reason: a hardcoded catalog of third-party
    /// model names goes stale within months and then quietly hands the
    /// user a 404. Returns `[]` on any error (server down, no model
    /// loaded, decode failure); the caller falls back to
    /// `availableModels`.
    static func fetchLoadedModels(
        baseURL: URL,
        urlSession: URLSession = .shared
    ) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return [] }
            return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
        } catch {
            return []
        }
    }
}
