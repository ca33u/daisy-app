//
//  MCPDispatcher.swift
//  Daisy
//
//  Runs a configured `MCPIntegration` against a finished session:
//
//   1. Build the placeholder map from the session (title, summary,
//      action items, follow-up, transcript, etc.)
//   2. Substitute into the integration's JSON arguments template
//   3. Open a short-lived MCPClient, call the configured tool, close
//   4. Surface success / failure via ToastCenter
//
//  No retries, no queueing — if it fails, the user re-fires from the
//  kebab menu. Keeps the path simple and predictable.
//

import Foundation
import os

@MainActor
enum MCPDispatcher {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "MCPDispatcher")

    /// Send `session` through `integration`. Idempotent from
    /// Daisy's side — re-sending creates another page/issue/etc on
    /// the destination side (we don't track previous sends).
    @discardableResult
    static func send(_ integration: MCPIntegration, for session: StoredSession) async -> Bool {
        await send(integration, placeholders: makePlaceholders(for: session)).ok
    }

    /// What a destination answered: whether it took it, and its reply
    /// (an MCP tool's text, a webhook's body) — where a created record's
    /// URL usually is.
    struct SendResult: Sendable {
        let ok: Bool
        let reply: String
        /// The first link in the reply, if any.
        var link: String? {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
            let range = NSRange(reply.startIndex..., in: reply)
            return detector.firstMatch(in: reply, range: range)?.url?.absoluteString
        }
    }

    /// Backlog 24 М-14: the same transports with any set of placeholder
    /// values — a session's, or one next step's.
    static func send(_ integration: MCPIntegration, placeholders: [(key: String, value: String)]) async -> SendResult {
        guard let url = URL(string: integration.baseURL), url.scheme != nil else {
            ToastCenter.shared.show("\(integration.name): invalid server URL", style: .error)
            return SendResult(ok: false, reply: "")
        }

        ToastCenter.shared.show("Sending to \(integration.name)…", style: .info)

        switch integration.kind {
        case .mcp:
            return await sendMCP(integration, to: url, placeholders: placeholders)
        case .webhook:
            return await sendWebhook(integration, to: url, placeholders: placeholders)
        }
    }

    /// MCP transport: open a JSON-RPC client, call the configured
    /// tool with substituted arguments.
    private static func sendMCP(
        _ integration: MCPIntegration,
        to url: URL,
        placeholders: [(key: String, value: String)]
    ) async -> SendResult {
        let arguments: AnyJSON
        do {
            arguments = try buildArguments(template: integration.argumentsTemplate, placeholders: placeholders)
        } catch {
            log.error("Template substitution failed: \(error.localizedDescription, privacy: .public)")
            ToastCenter.shared.show("\(integration.name): \(error.localizedDescription)", style: .error)
            return SendResult(ok: false, reply: "")
        }

        let client = MCPClient(baseURL: url)
        do {
            try await client.connect()
            try await client.initialize()
            let text = try await client.callTool(name: integration.toolName, arguments: arguments)
            client.disconnect()
            let snippet = text.isEmpty ? "" : " — " + String(text.prefix(80))
            ToastCenter.shared.show("Sent to \(integration.name)\(snippet)", style: .success)
            log.info("MCP send to \(integration.name, privacy: .private): ok")
            return SendResult(ok: true, reply: text)
        } catch {
            client.disconnect()
            log.error("MCP send to \(integration.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            ToastCenter.shared.show("\(integration.name): \(error.localizedDescription)", style: .error)
            return SendResult(ok: false, reply: "")
        }
    }

    /// Webhook transport: substitute placeholders into the template,
    /// validate it parses as JSON, POST to the URL with
    /// `Content-Type: application/json`. Success = any 2xx response.
    private static func sendWebhook(
        _ integration: MCPIntegration,
        to url: URL,
        placeholders: [(key: String, value: String)]
    ) async -> SendResult {
        // Reuse the same template substitution + JSON validation as
        // the MCP path so a malformed template fails the same way
        // regardless of transport (better error messages).
        let bodyData: Data
        do {
            // Substitute manually here — we want the raw bytes back
            // for the POST body, not an AnyJSON wrapper.
            var rendered = integration.argumentsTemplate
            for (key, value) in placeholders {
                rendered = rendered.replacingOccurrences(of: key, with: escapeForJSONString(value))
            }
            guard let data = rendered.data(using: .utf8) else {
                throw DispatcherError.encodingFailed
            }
            // Validate it parses as JSON — surface template errors
            // before we hand garbage to the receiver.
            _ = try JSONSerialization.jsonObject(with: data)
            bodyData = data
        } catch {
            log.error("Webhook template error: \(error.localizedDescription, privacy: .public)")
            ToastCenter.shared.show("\(integration.name): \(error.localizedDescription)", style: .error)
            return SendResult(ok: false, reply: "")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Bearer auth is opt-in per integration — set the header
        // only when the user actually provided a token. Slack
        // incoming webhooks etc. don't want one; Attio / Linear
        // REST / most SaaS APIs require it.
        let token = integration.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                ToastCenter.shared.show("\(integration.name): no response", style: .error)
                return SendResult(ok: false, reply: "")
            }
            if (200..<300).contains(http.statusCode) {
                ToastCenter.shared.show("Sent to \(integration.name)", style: .success)
                log.info("Webhook send to \(integration.name, privacy: .private): \(http.statusCode)")
                return SendResult(ok: true, reply: String(data: data.prefix(8192), encoding: .utf8) ?? "")
            } else {
                ToastCenter.shared.show("\(integration.name): HTTP \(http.statusCode)", style: .error)
                log.error("Webhook send to \(integration.name, privacy: .private) failed: HTTP \(http.statusCode)")
                return SendResult(ok: false, reply: "")
            }
        } catch {
            log.error("Webhook send to \(integration.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            ToastCenter.shared.show("\(integration.name): \(error.localizedDescription)", style: .error)
            return SendResult(ok: false, reply: "")
        }
    }

    // MARK: - Placeholders

    /// What `{{...}}` keys the dispatcher knows. Order matters in
    /// the substitution loop (longest prefix first) so that, e.g.,
    /// `{{actionItemsBullets}}` doesn't get mangled by an earlier
    /// pass over `{{actionItems}}`.
    static func makePlaceholders(for session: StoredSession) -> [(key: String, value: String)] {
        let summary = session.summary
        let actionItems = summary?.actionItems ?? []
        let bullets = actionItems.map { "- " + $0 }.joined(separator: "\n")
        let joined = actionItems.joined(separator: "; ")
        return [
            // Longest first so prefix-overlapping keys don't collide.
            ("{{actionItemsBullets}}", bullets),
            ("{{clientFollowUp}}", summary?.clientFollowUp ?? ""),
            ("{{actionItems}}", joined),
            ("{{transcript}}", session.transcriptText),
            ("{{summary}}", summary?.summary ?? ""),
            ("{{folder}}", session.folderSlug),
            ("{{locale}}", session.locale),
            ("{{title}}", session.title),
            ("{{date}}", ISO8601DateFormatter().string(from: session.startedAt)),
        ]
    }

    private static func buildArguments(
        template: String,
        placeholders: [(key: String, value: String)]
    ) throws -> AnyJSON {
        var t = template
        for (key, value) in placeholders {
            t = t.replacingOccurrences(of: key, with: escapeForJSONString(value))
        }
        guard let data = t.data(using: .utf8) else {
            throw DispatcherError.encodingFailed
        }
        do {
            return try JSONDecoder().decode(AnyJSON.self, from: data)
        } catch {
            throw DispatcherError.invalidJSON(error.localizedDescription)
        }
    }

    /// Escape a string for safe drop-in between double-quotes inside
    /// a JSON template. Mirrors the escape table MCPSummarizer uses
    /// for the same reason; kept duplicated to avoid coupling the two
    /// templating call sites.
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

    // MARK: - Errors

    private enum DispatcherError: LocalizedError {
        case encodingFailed
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Couldn't encode the arguments template as UTF-8."
            case .invalidJSON(let detail):
                return "Arguments template isn't valid JSON after substitution: \(detail)"
            }
        }
    }
}
