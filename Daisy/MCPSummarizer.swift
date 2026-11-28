// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MCPSummarizer.swift
//  Daisy
//
//  SummaryProvider that talks to a user-configured MCP server which
//  wraps a local LLM (Ollama, llama.cpp, LM Studio, etc.). Closes the
//  gap Apple Intelligence leaves around Russian, Ukrainian, Polish
//  and other languages without sending the transcript over the wire.
//
//  How it works:
//   1. The user runs an MCP server locally that exposes their LLM as
//      a tool — e.g. an Ollama-MCP wrapper with a `chat` tool that
//      takes `{model, messages}`.
//   2. They paste the server URL + tool name + JSON arguments
//      template into Daisy's Settings → Summary → MCP section.
//   3. On `summarize()`, Daisy substitutes `{{system}}` /
//      `{{transcript}}` / `{{title}}` into the template, sends
//      `tools/call`, parses the text response into a MeetingSummary.
//
//  Transport: HTTP+SSE only for now (same as MCPServer). stdio
//  transport would let us launch the wrapper subprocess ourselves,
//  but stdio + sandbox is fiddly — leave for later.
//

import Foundation
import os

nonisolated struct MCPSummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .mcp

    /// HTTP+SSE base URL of the MCP server. The client appends `/sse`
    /// to open the stream.
    let baseURL: URL
    /// Tool name to call on the server (e.g. "chat", "complete",
    /// "ollama_chat"). Server-specific; user picks per their wrapper.
    let toolName: String
    /// JSON template with `{{system}}`, `{{transcript}}`, `{{title}}`
    /// placeholders. Substituted into a JSON object that becomes the
    /// `arguments` field of the `tools/call`.
    let argumentsTemplate: String

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MCPSummarizer")

    /// Asked once more right before the tool is called, and the call is
    /// given up if it throws. `connect` and `initialize` are network round
    /// trips of their own, after the caller's last look at whether the
    /// text may go: the dictation cleanup re-checks its switch and its yes
    /// here, so one taken back during the handshake sends no text
    /// (`Summarizer.cleanDictation`). nil for every other task.
    var beforeToolCall: (@Sendable () async throws -> Void)?

    init(baseURL: URL, toolName: String, argumentsTemplate: String) {
        self.baseURL = baseURL
        self.toolName = toolName
        self.argumentsTemplate = argumentsTemplate
    }

    func isReady() async -> Bool {
        // Cheap reachability probe: TCP-connect to the MCP server's
        // SSE endpoint with a 2-second deadline. We do NOT complete
        // the handshake (no `initialize` request, no `tools/list`),
        // just verify there's something accepting HTTP at the URL.
        // That keeps the probe cheap enough to run on Settings open
        // without waking heavyweight model-load paths inside the
        // user's wrapper.
        //
        // Pre-build-40: this just checked non-empty `toolName` and
        // `argumentsTemplate` and returned true. The summarizer
        // reported `.available` even when the MCP server was off,
        // and the user found out only after they'd recorded a 45-min
        // meeting and waited through a long handshake-timeout error.
        // Pre-PH audit (2026-05-28) flagged it; this is the fix.
        guard !toolName.trimmingCharacters(in: .whitespaces).isEmpty,
              !argumentsTemplate.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("sse"))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 2

        do {
            // We don't care about the body — only that the server
            // responds within the deadline. URLSession.data won't
            // fire until either the response is complete OR the
            // timeout hits; for SSE that would never return because
            // the stream stays open. Wrap in a Task that cancels
            // itself after the timeout.
            let probeTask = Task<Bool, Never> {
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse {
                        return (200..<500).contains(http.statusCode)
                    }
                    return false
                } catch {
                    return false
                }
            }
            // Race the probe against a 2.5s wall-clock deadline so an
            // open-and-blocking SSE stream doesn't pin the Settings UI.
            let deadline = Task<Bool, Never> {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                return false
            }
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask { await probeTask.value }
                group.addTask { await deadline.value }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
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

        let arguments = try buildArguments(
            system: systemPrompt,
            transcript: userPrompt,
            title: title
        )

        // The client is single-use per summarize — short-lived, no
        // pool. LLM calls are minutes apart so the connection setup
        // cost is negligible against the model's own latency.
        // `init` and `disconnect()` are not async in MCPClient (the
        // class is @MainActor but the calls are reachable here
        // without crossing isolation, per Swift 6's inference), so
        // no `await` on those — only on the real I/O methods.
        let client = MCPClient(baseURL: baseURL)
        do {
            try await client.connect()
            try await client.initialize()
            // Nothing of the text has been sent so far.
            try await beforeToolCall?()
            let text = try await client.callTool(name: toolName, arguments: arguments)
            client.disconnect()
            return try parse(text)
        } catch let denied as DictationCleanup.NotPermitted {
            // Not an MCP error: its own reason goes up as it is.
            client.disconnect()
            throw denied
        } catch {
            client.disconnect()
            throw mapError(error)
        }
    }

    // MARK: - Template substitution

    /// Substitute placeholders into the template and parse the
    /// result as AnyJSON. We escape values for JSON safety — the
    /// user wrote the template, we write the values, and the JSON
    /// stays well-formed.
    private func buildArguments(
        system: String,
        transcript: String,
        title: String
    ) throws -> AnyJSON {
        var t = argumentsTemplate
        t = t.replacingOccurrences(of: "{{system}}", with: Self.escapeForJSONString(system))
        t = t.replacingOccurrences(of: "{{transcript}}", with: Self.escapeForJSONString(transcript))
        t = t.replacingOccurrences(of: "{{title}}", with: Self.escapeForJSONString(title))

        guard let data = t.data(using: .utf8) else {
            throw SummaryProviderError.parseFailed(
                provider: "MCP",
                message: "Arguments template isn't valid UTF-8"
            )
        }
        do {
            return try JSONDecoder().decode(AnyJSON.self, from: data)
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "MCP",
                message: "Arguments template isn't valid JSON after substitution: \(error.localizedDescription)"
            )
        }
    }

    /// Escape a string so it can be dropped between double-quotes
    /// inside a JSON template without breaking the parse. Handles
    /// the standard JSON escapes; assumes UTF-8 input.
    private static func escapeForJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":   out += "\\\""
            case "\\":   out += "\\\\"
            case "\n":   out += "\\n"
            case "\r":   out += "\\r"
            case "\t":   out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Response parsing

    private func parse(_ text: String) throws -> MeetingSummary {
        do {
            let dto = try CloudSummaryDTO.decode(from: text)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "MCP",
                message: error.localizedDescription
            )
        }
    }

    private func mapError(_ error: Error) -> Error {
        if let already = error as? SummaryProviderError {
            return already
        }
        if let mcp = error as? MCPClientError {
            switch mcp {
            case .invalidURL:
                return SummaryProviderError.modelUnavailable(provider: "MCP", reason: mcp.localizedDescription)
            case .noEndpointReceived, .streamFailed, .timeout, .cancelled:
                return SummaryProviderError.modelUnavailable(provider: "MCP", reason: mcp.localizedDescription)
            case .requestFailed(let status, let body):
                return SummaryProviderError.httpError(provider: "MCP", status: status, body: body)
            case .responseError(_, let message):
                return SummaryProviderError.parseFailed(provider: "MCP", message: message)
            }
        }
        return SummaryProviderError.modelUnavailable(provider: "MCP", reason: error.localizedDescription)
    }

    // MARK: - Defaults

    /// Default Ollama-MCP shape. Most local-LLM MCP wrappers expose
    /// either a `chat` tool or a `complete` tool — we ship a sane
    /// default that the user can edit.
    static let defaultToolName = "chat"

    static let defaultArgumentsTemplate: String = """
    {
      "model": "qwen3.5:4b",
      "messages": [
        {"role": "system", "content": "{{system}}"},
        {"role": "user", "content": "{{transcript}}"}
      ],
      "format": "json"
    }
    """

    static let defaultBaseURLString = "http://127.0.0.1:11435"
}
