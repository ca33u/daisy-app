// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  AttendeeWebResearch.swift
//  Daisy
//
//  Optional online-research augmentation for the pre-meeting brief. When
//  the user opts in (`AppSettings.preMeetingBriefResearchOnline`) AND an
//  Anthropic API key is present, this runs one short Anthropic Messages
//  call with the `web_search` tool to gather a few public, current facts
//  about the meeting's attendees / their company. The result is folded
//  into the brief dossier as a clearly-labelled "WEB CONTEXT" block.
//
//  This is the ONLY part of the brief that touches the network, and it is
//  entirely best-effort: any missing key, HTTP error, or parse failure
//  returns nil and the brief proceeds from local history alone.
//
//  Requires an Anthropic key specifically (it's the web_search tool we
//  use). Independent of the chosen SUMMARY provider — a user can run
//  local summaries and still opt into Anthropic-powered research.
//

import Foundation
import os

// `nonisolated` so the network call + JSON parse run off the main actor
// (called with `await` from the @MainActor brief store).
nonisolated enum AttendeeWebResearch {
    /// Cheapest capable Anthropic model — research is a gathering pass,
    /// not a reasoning-heavy one.
    private static let model = "claude-haiku-4-5-20251001"
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AttendeeWebResearch")

    struct Result: Sendable {
        let text: String
        let sources: [WebSource]
    }

    /// Best-effort. Returns nil when there's no Anthropic key, nothing
    /// worth researching, or any failure. Never throws.
    static func research(for meeting: DaisyMeeting) async -> Result? {
        guard let apiKey = KeychainStore.get(account: SecretKey.anthropicAPIKey),
              !apiKey.isEmpty else {
            return nil
        }
        // Need at least a name or a title to search on.
        let attendees = meeting.attendees.filter { !$0.isEmpty }
        guard !attendees.isEmpty || !meeting.title.isEmpty else { return nil }

        let who = attendees.isEmpty ? meeting.title : attendees.joined(separator: ", ")
        let prompt = """
        I have a business meeting titled "\(meeting.title)" with: \(who).

        Search the web and give me 3-6 short bullet points of PUBLIC, \
        current facts that would help me walk in prepared — the person's \
        role/company, recent company news or funding, product launches, \
        or anything topical from the last few months. Only include facts \
        you can source. If you can't find reliable information about them, \
        reply with a single line saying so. Keep it under 150 words. No \
        preamble, just the bullets.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
            "tools": [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 3
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 45
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            return nil
        }

        do {
            let (data, response) = try await CloudHTTPRetry.fetch(
                request: request,
                session: .shared,
                log: log
            )
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.error("Web research HTTP failure")
                return nil
            }
            return parse(data: data)
        } catch {
            log.error("Web research request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pull the assistant's text + any web-search result URLs out of the
    /// Anthropic response content blocks. Defensive — unknown shapes are
    /// simply skipped.
    private static func parse(data: Data) -> Result? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Book the spend BEFORE the content check: this call bypasses
        // SummaryProvider entirely, and its `web_search` server tool is
        // billed PER SEARCH — the most expensive thing Daisy can trigger
        // per unit. It was charged whether or not we can parse the
        // bullets out, so an unusable response still gets recorded.
        // Note this always bills the ANTHROPIC key regardless of which
        // provider is selected for summaries.
        TokenLedgerSink.recordAnthropic(model: model, json: json)

        guard let content = json["content"] as? [[String: Any]] else {
            return nil
        }

        var textParts: [String] = []
        var sources: [WebSource] = []
        var seenURLs = Set<String>()

        for block in content {
            let type = block["type"] as? String
            switch type {
            case "text":
                if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !t.isEmpty {
                    textParts.append(t)
                }
                // Citations attached to a text block also carry URLs.
                if let citations = block["citations"] as? [[String: Any]] {
                    for c in citations {
                        if let url = c["url"] as? String, seenURLs.insert(url).inserted {
                            let title = (c["title"] as? String) ?? url
                            sources.append(WebSource(title: title, url: url))
                        }
                    }
                }
            case "web_search_tool_result":
                // content is an array of web_search_result items.
                if let results = block["content"] as? [[String: Any]] {
                    for r in results {
                        if let url = r["url"] as? String, seenURLs.insert(url).inserted {
                            let title = (r["title"] as? String) ?? url
                            sources.append(WebSource(title: title, url: url))
                        }
                    }
                }
            default:
                break
            }
        }

        let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Result(text: text, sources: Array(sources.prefix(6)))
    }
}
