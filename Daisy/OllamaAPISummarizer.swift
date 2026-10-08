//
//  OllamaAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that talks to a locally-running Ollama (https://ollama.com)
//  via its native `/api/chat` REST endpoint. No API key required — Ollama
//  binds to 127.0.0.1:11434 by default and accepts unauthenticated requests
//  from localhost. Data never leaves the Mac.
//
//  Why this exists as a first-class provider (build 40):
//  Pre-build-40 the user-visible "Ollama" option in Settings → Summary
//  Provider routed through `MCPSummarizer` with a preset baseURL and a
//  JSON arguments template that assumed an MCP+SSE shim was running. But
//  stock Ollama does NOT speak MCP — it speaks its own REST. Picking
//  "Ollama" in Daisy without first installing `mcp-ollama` (or similar)
//  caused every summary to fail with a cryptic
//  "MCP server didn't send an `endpoint` event within the handshake window."
//  message. The pre-PH audit (2026-05-28) flagged this as a P0 blocker:
//  every PH visitor copy-pasting Ollama would hit it.
//
//  This adapter posts to `/api/chat` directly, asks for `format: "json"`,
//  and parses the resulting `message.content` as the standard
//  `CloudSummaryDTO` shape. Probe via `/api/tags`.
//

import Foundation
import os

nonisolated struct OllamaAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .ollama

    /// Base URL of the Ollama server. Default: `http://127.0.0.1:11434`.
    /// User can override in Settings if they've remapped Ollama to a
    /// non-default port (rare but possible — e.g. running it inside a
    /// container with port forwarding).
    let baseURL: URL

    /// Ollama model identifier. Must already be pulled locally
    /// (`ollama pull <model>`). Reasonable defaults below.
    let model: String

    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OllamaSummarizer")

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = defaultModelID,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.urlSession = urlSession
    }

    /// "Is Ollama actually running and answering?" probe via `/api/tags`.
    /// Cheap (no model load, just a directory listing). Returns false on
    /// any network error or non-2xx status — Settings UI flips the
    /// provider pill to "unavailable" so the user knows before they
    /// record a 45-minute meeting.
    func isReady() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2 // tight — Ollama on localhost responds <50ms
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

        // Ollama /api/chat request shape:
        //   { model, messages: [{role, content}], format: "json",
        //     stream: false, options: { num_ctx, temperature } }
        // `format: "json"` makes Ollama constrain output to valid JSON
        // (its equivalent of OpenAI's JSON mode). `stream: false` so we
        // get one response object back instead of NDJSON chunks.
        // `num_ctx: 16384` — wider context than Ollama's default 2048
        // so a 30-min meeting transcript fits. Bigger contexts cost RAM
        // (~250MB per 8k tokens on llama3.2), but a meeting summarizer
        // is the worst case for context starvation; defaults are wrong
        // here.
        // Dynamic context sizing. A fixed 16k num_ctx silently TRUNCATED
        // long meetings: an hour of Russian speech is ~20-30k tokens, and
        // Ollama drops the overflow from the TOP of the prompt — i.e. the
        // system message with the JSON schema and safety boundary goes
        // first, producing empty/invalid summaries with no diagnostics.
        // Estimate ~3 chars/token (safe for Cyrillic-heavy text), pad for
        // the response, round up to the model's likely limits. Ollama
        // clamps num_ctx to the model's own maximum, so over-asking is
        // safe (just RAM); under-asking is the silent-truncation bug.
        let promptChars = systemPrompt.count + userPrompt.count
        let estTokens = promptChars / 3 + 4_096
        let numCtx = min(131_072, max(16_384, estTokens))
        if estTokens > 131_072 {
            log.warning("Ollama prompt (~\(estTokens) tokens) exceeds the 128k ceiling — the summary may be truncated. Consider a cloud provider for this recording.")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "format": "json",
            "stream": false,
            "options": [
                "num_ctx": numCtx,
                // Some Ollama versions default num_predict to 128 —
                // mid-sentence truncation of the JSON. 4k covers the
                // largest summary the schema can produce.
                "num_predict": 4_096,
                "temperature": 0.4
            ]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Big timeout — Ollama on M-series Mac can take 30-60s for a
        // 30-min meeting through llama3.2:8b. cold-loaded models add
        // another ~10s on first call.
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            // Localhost network errors usually mean Ollama is not
            // running. Translate to a friendlier provider error so
            // the UI can suggest the fix ("Open Terminal, run
            // `ollama serve`") instead of dumping the raw network
            // error.
            throw SummaryProviderError.modelUnavailable(
                provider: "Ollama",
                reason: "Couldn't reach Ollama at \(baseURL.absoluteString). Make sure `ollama serve` is running, then try again. (\(error.localizedDescription))"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: "Ollama")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? "<empty>"
            log.error("Ollama HTTP \(http.statusCode): \(bodyString, privacy: .private)")
            // Common Ollama failure: 404 with `{"error":"model 'X' not found"}`.
            // Surface that verbatim — it's the actionable case.
            throw SummaryProviderError.httpError(
                provider: "Ollama",
                status: http.statusCode,
                body: bodyString
            )
        }

        // Response shape: { "message": { "role": "assistant", "content": "<JSON>" }, ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.invalidResponse(provider: "Ollama")
        }

        // Local and free, but the usage is still useful volume data. Keep
        // it even if a server returned an unusable content shape.
        TokenLedgerSink.record(
            provider: .ollama,
            model: model,
            spend: .ollama(from: json)
        )

        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: "Ollama")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: content)
            return dto.toMeetingSummary()
        } catch {
            // `num_ctx` above asks for a window wide enough, but Ollama
            // CLAMPS it to the model's own maximum — so a model built at
            // 8k still trims a 30k prompt, from the top, taking the JSON
            // schema with it. Same misdiagnosis as LM Studio, same fix:
            // name the real problem instead of blaming the JSON.
            let estimated = LocalContextGuard.estimatedTokens(promptChars: promptChars)
            let reported = LocalContextGuard.positive(json["prompt_eval_count"])
            // `numCtx`, not a constant: we already asked for a window
            // sized to this prompt, so an overflow here means the
            // MODEL's own ceiling clamped us — the only case worth
            // reporting. Meetings only, for the same reason as LM Studio.
            if case .meeting = task, LocalContextGuard.truncationSuspected(
                estimatedTokens: estimated,
                reportedPromptTokens: reported,
                windowTokens: numCtx
            ) {
                log.error("Ollama context overflow: est ~\(estimated) tokens, model read \(reported ?? -1)")
                throw SummaryProviderError.contextOverflow(
                    provider: "Ollama",
                    approxPromptTokens: estimated,
                    reportedPromptTokens: reported
                )
            }
            throw SummaryProviderError.parseFailed(
                provider: "Ollama",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog

    /// Default model. `qwen3.5:4b` is the current best
    /// small-enough-to-pull / capable-enough-for-meeting-summaries
    /// trade: ~3.4 GB, strong multilingual (Daisy summarises Russian
    /// meetings routinely, where the 3B Llamas were visibly weaker),
    /// and a 256K context so a long meeting doesn't need chunking.
    /// User can override in Settings.
    ///
    /// It is a thinking-capable model, which is fine here: Ollama puts
    /// the reasoning trace in `message.thinking`, so `message.content`
    /// is still the bare JSON `format: "json"` asked for.
    static let defaultModelID = "qwen3.5:4b"

    /// Default base URL. Stock Ollama binds here.
    static let defaultBaseURLString = "http://127.0.0.1:11434"

    /// Catalog of well-known Ollama models. This is a FALLBACK and a
    /// source of friendly labels — the picker prefers the live
    /// `/api/tags` listing, so whatever the user has actually pulled
    /// wins. User-typed model IDs are also accepted (free text field).
    ///
    /// Refreshed 2026-10-08; sizes are the default-quant download sizes
    /// from ollama.com/library. Gemma 4 is new (e2b / e4b / 12b fit a
    /// 16 GB Mac); Qwen 3.6 and 3.8 come only at 27B and up, so Qwen 3.5
    /// stays the small default. Gemma 3, GPT-OSS and Llama haven't been
    /// updated in a year or more — kept for anyone who already has them.
    static let availableModels: [(id: String, label: String)] = [
        ("qwen3.5:4b",             "Qwen 3.5 4B (~3.3 GB) — recommended"),
        ("qwen3.5:9b",             "Qwen 3.5 9B (~6.6 GB) — more capable"),
        ("gemma4:e4b",             "Gemma 4 E4B (~6.6 GB) — multilingual"),
        ("gemma4:12b",             "Gemma 4 12B (~8 GB) — more capable"),
        ("gemma4:e2b",             "Gemma 4 E2B (~4.6 GB) — smallest Gemma 4"),
        ("qwen3.5:27b",            "Qwen 3.5 27B (~17 GB) — needs a 32 GB Mac"),
        ("gemma3:4b",              "Gemma 3 4B (~3.3 GB) — older"),
        ("gemma3:12b",             "Gemma 3 12B (~8.1 GB) — older"),
        ("gpt-oss:20b",            "GPT-OSS 20B (~13 GB)"),
        ("llama3.1:8b",            "Llama 3.1 8B (~4.7 GB) — older, widely installed"),
        ("llama3.2:latest",        "Llama 3.2 3B (~2 GB) — older, smallest"),
    ]

    // MARK: - Cloud-model detection

    /// True when a model id is one of Ollama's hosted **cloud** models.
    /// Ollama names these with a `:cloud` (e.g. `gpt-oss:120b-cloud`,
    /// `qwen3-coder:480b-cloud`) or `-cloud` suffix; the LOCAL daemon
    /// transparently proxies a chat request for such a model out to
    /// ollama.com. So even though Daisy still POSTs to 127.0.0.1, the
    /// transcript leaves the Mac — the privacy copy must say so, and
    /// `SummaryProviderKind`'s model-aware label helpers key off this.
    static func isCloudModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.hasSuffix(":cloud") || lowered.hasSuffix("-cloud")
    }

    // MARK: - Installed-model listing

    private struct TagsResponse: Decodable {
        struct Entry: Decodable { let name: String }
        let models: [Entry]
    }

    /// The models this Ollama server actually knows about, via
    /// `/api/tags` — the same endpoint `isReady()` probes, here read for
    /// its payload. Drives the Settings picker so the list reflects what
    /// the user has really pulled (plus any spooled `:cloud` stubs)
    /// instead of a hardcoded catalog that silently goes stale. Returns
    /// `[]` on any error (server down, decode failure); the caller falls
    /// back to `availableModels`.
    static func fetchInstalledModels(
        baseURL: URL,
        urlSession: URLSession = .shared
    ) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map(\.name)
        } catch {
            return []
        }
    }
}
