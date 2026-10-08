//
//  CloudText.swift
//  DaisyCore
//
//  One text completion through the provider whose key the person has —
//  the same three the summary uses, the same key, the same retries. For
//  what is not a meeting summary: questions about a meeting (the phone's
//  chat, 28.09), people worth following up (leads), a document's gist.
//
//  The summary keeps its own call (`SummaryProvider`): its prompt, its
//  JSON contract and its decode are the summary's alone.
//

import Foundation
import os

public nonisolated enum CloudText {
    public struct Message: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public var role: Role
        public var text: String
        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    private static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "CloudText")

    /// The reply to `messages` under `system`. `json` asks the provider
    /// for a JSON object where it can be asked (OpenAI, Kimi); the
    /// Anthropic prompt must say so itself.
    public static func complete(
        kind: SummaryProviderKind,
        system: String,
        messages: [Message],
        maxTokens: Int = 2048,
        json: Bool = false
    ) async throws -> String {
        let provider = kind.displayName
        guard let apiKey = KeychainStore.get(account: kind.keyAccount), !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: provider)
        }
        if kind == .anthropic {
            // Streamed (2026-10-08): Claude 5 models think by default, and
            // a short `maxTokens` could be spent on thinking alone — the
            // ceiling is raised for the modern models; only what's
            // generated is billed. Low effort: these are short replies.
            let body = AnthropicStreaming.body(
                model: AnthropicSummaryProvider.defaultModelID,
                maxTokens: maxTokens,
                effort: "low",
                system: system,
                messages: messages.map { ["role": $0.role.rawValue, "content": $0.text] }
            )
            let text = try await AnthropicStreaming.text(
                try AnthropicStreaming.request(apiKey: apiKey, body: body), provider: provider, log: log)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // OpenAI and Kimi: one chat-completions round trip.
        let model = kind == .openai ? OpenAISummaryProvider.defaultModelID : KimiSummaryProvider.defaultModelID
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]]
                + messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        if kind == .kimi {
            KimiSummaryProvider.applyParameters(to: &body, model: model, answerTokens: maxTokens)
        } else if OpenAISummaryProvider.usesGPT5ParameterSet(model) {
            body["max_completion_tokens"] = max(maxTokens, 8192)
        } else {
            body["max_tokens"] = maxTokens
        }
        var request = URLRequest(url: kind == .openai
                                 ? URL(string: "https://api.openai.com/v1/chat/completions")!
                                 : KimiSummaryProvider.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.httpMethod = "POST"
        request.timeoutInterval = kind == .kimi ? 120 : 60

        let reply = try await CloudSummaryCall.send(request, provider: provider, log: log)
        let text = try CloudSummaryCall.chatContent(reply, provider: provider)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryProviderError.invalidResponse(provider: provider) }
        return trimmed
    }

    /// The first `{ … }` in a reply — models wrap JSON in prose or fences.
    public static func jsonObject(in reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
