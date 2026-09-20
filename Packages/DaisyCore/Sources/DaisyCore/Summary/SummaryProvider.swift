//
//  SummaryProvider.swift
//  DaisyCore
//
//  Copied (the cloud subset) from daisy-app/Daisy/SummaryProvider.swift
//  @ 1.0.7.72, 2026-09-19 — backlog 4 B-2. The phone has the three
//  key-based cloud providers the Mac has; Apple Intelligence, the
//  local servers (Ollama / LM Studio / MCP) and the agent CLIs are Mac
//  things. Same prompt, same JSON schema, same `summary.json` — a
//  summary made here is indistinguishable from one made on the Mac.
//

import Foundation
import os

public nonisolated enum SummaryProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case kimi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .kimi: "Kimi"
        }
    }

    /// The `SecretKey` account the provider's API key lives under —
    /// the same account the Mac writes, so iCloud Keychain carries it.
    public var keyAccount: String {
        switch self {
        case .anthropic: SecretKey.anthropicAPIKey
        case .openai: SecretKey.openaiAPIKey
        case .kimi: SecretKey.kimiAPIKey
        }
    }

    public var hasKey: Bool {
        guard let key = KeychainStore.get(account: keyAccount) else { return false }
        return !key.isEmpty
    }

    public func makeProvider() -> any SummaryProvider {
        switch self {
        case .anthropic: AnthropicSummaryProvider()
        case .openai: OpenAISummaryProvider()
        case .kimi: KimiSummaryProvider()
        }
    }
}

public nonisolated protocol SummaryProvider: Sendable {
    var kind: SummaryProviderKind { get }
    func summarize(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary
}

public nonisolated enum SummaryProviderError: LocalizedError, Sendable {
    case missingAPIKey(provider: String)
    case invalidResponse(provider: String)
    case httpError(provider: String, status: Int, body: String)
    case parseFailed(provider: String, message: String)
    case transcriptTooShort

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): "\(p): no API key."
        case .invalidResponse(let p): "\(p): unexpected response from the API."
        case .httpError(let p, let status, _): "\(p): HTTP \(status)."
        case .parseFailed(let p, let message): "\(p): \(message)"
        case .transcriptTooShort: "The transcript is too short to summarize."
        }
    }
}

/// Shared by the three providers: the guard rails, the prompt pair, the
/// HTTP round trip with retries, the tolerant decode.
nonisolated enum CloudSummaryCall {
    static func prepare(transcript: String, keyAccount: String, provider: String) throws -> (transcript: String, apiKey: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { throw SummaryProviderError.transcriptTooShort }
        guard let apiKey = KeychainStore.get(account: keyAccount), !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: provider)
        }
        return (trimmed, apiKey)
    }

    static func send(_ request: URLRequest, provider: String, log: Logger) async throws -> [String: Any] {
        let (data, response) = try await CloudHTTPRetry.fetch(request: request, session: .shared, log: log)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: provider)
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            // Body stays private: 4xx replies can quote the prompt back.
            log.error("\(provider, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(body, privacy: .private)")
            throw SummaryProviderError.httpError(provider: provider, status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.invalidResponse(provider: provider)
        }
        return json
    }

    static func decode(_ text: String, provider: String) throws -> MeetingSummary {
        do {
            return try CloudSummaryDTO.decode(from: text).toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(provider: provider, message: error.localizedDescription)
        }
    }

    /// OpenAI-compatible chat completions: `choices[0].message.content`.
    static func chatContent(_ json: [String: Any], provider: String) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: provider)
        }
        return content
    }
}

// MARK: - Anthropic

public nonisolated struct AnthropicSummaryProvider: SummaryProvider {
    public let kind: SummaryProviderKind = .anthropic
    public static let defaultModelID = "claude-sonnet-5"
    let model: String
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "AnthropicSummarizer")

    public init(model: String = defaultModelID) { self.model = model }

    public func summarize(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary {
        let (text, apiKey) = try CloudSummaryCall.prepare(transcript: transcript, keyAccount: SecretKey.anthropicAPIKey, provider: "Anthropic")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": SummaryPrompt.meetingSystemInstructions(localeHint: localeHint),
            "messages": [["role": "user", "content": SummaryPrompt.meetingUserPrompt(title: title, transcript: text)]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await CloudSummaryCall.send(request, provider: "Anthropic", log: log)
        // Every TEXT block joined — thinking / tool blocks may come first.
        guard let content = json["content"] as? [[String: Any]] else {
            throw SummaryProviderError.invalidResponse(provider: "Anthropic")
        }
        let reply = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryProviderError.invalidResponse(provider: "Anthropic")
        }
        return try CloudSummaryCall.decode(reply, provider: "Anthropic")
    }
}

// MARK: - OpenAI

public nonisolated struct OpenAISummaryProvider: SummaryProvider {
    public let kind: SummaryProviderKind = .openai
    public static let defaultModelID = "gpt-5.6-terra"
    let model: String
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "OpenAISummarizer")

    public init(model: String = defaultModelID) { self.model = model }

    /// GPT-5 / o-series take `max_completion_tokens` and refuse a custom temperature.
    static func usesGPT5ParameterSet(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }

    public func summarize(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary {
        let (text, apiKey) = try CloudSummaryCall.prepare(transcript: transcript, keyAccount: SecretKey.openaiAPIKey, provider: "OpenAI")
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": SummaryPrompt.meetingSystemInstructions(localeHint: localeHint)],
                ["role": "user", "content": SummaryPrompt.meetingUserPrompt(title: title, transcript: text)],
            ],
            "response_format": ["type": "json_object"],
        ]
        if Self.usesGPT5ParameterSet(model) {
            body["max_completion_tokens"] = 16_384
        } else {
            body["max_tokens"] = 4096
            body["temperature"] = 0.4
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await CloudSummaryCall.send(request, provider: "OpenAI", log: log)
        return try CloudSummaryCall.decode(CloudSummaryCall.chatContent(json, provider: "OpenAI"), provider: "OpenAI")
    }
}

// MARK: - Kimi (Moonshot)

public nonisolated struct KimiSummaryProvider: SummaryProvider {
    public let kind: SummaryProviderKind = .kimi
    public static let defaultModelID = "kimi-k2.6"
    static let endpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    let model: String
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "KimiSummarizer")

    public init(model: String = defaultModelID) { self.model = model }

    static func isThinkingModel(_ model: String) -> Bool { model.lowercased().hasPrefix("kimi-k3") }

    public func summarize(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary {
        let (text, apiKey) = try CloudSummaryCall.prepare(transcript: transcript, keyAccount: SecretKey.kimiAPIKey, provider: "Kimi")
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": SummaryPrompt.meetingSystemInstructions(localeHint: localeHint)],
                ["role": "user", "content": SummaryPrompt.meetingUserPrompt(title: title, transcript: text)],
            ],
            "response_format": ["type": "json_object"],
        ]
        if Self.isThinkingModel(model) {
            body["max_completion_tokens"] = 16_384
        } else {
            body["max_tokens"] = 4096
            body["temperature"] = 0.4
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await CloudSummaryCall.send(request, provider: "Kimi", log: log)
        return try CloudSummaryCall.decode(CloudSummaryCall.chatContent(json, provider: "Kimi"), provider: "Kimi")
    }
}
