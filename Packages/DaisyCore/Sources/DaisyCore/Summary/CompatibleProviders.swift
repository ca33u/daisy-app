//
//  CompatibleProviders.swift
//  DaisyCore
//
//  DeepSeek, GigaChat (cloud.ru), YandexGPT, Gemini and Grok on the
//  phone (Egor 04.11): the Mac already puts their keys into iCloud
//  Keychain, and for people in Russia these are the providers that
//  work. Endpoints, models, headers and parameters follow the Mac's
//  adapters in daisy-app/Daisy (DeepSeekAPISummarizer,
//  GigaChatAPISummarizer, YandexAPISummarizer, GeminiAPISummarizer,
//  GrokAPISummarizer @ 81405c2); the headers there say why each one is
//  as it is. What differs here:
//
//   • One round trip, not a stream — as the phone's OpenAI and Kimi
//     calls. The timeout is generous instead.
//   • The default model only. The Mac's model picker stays on the Mac.
//   • No `response_format` for any of them, as on the Mac: the prompt
//     asks for JSON and `CloudSummaryDTO.decode` finds the object.
//   • Grok's reply is not held to the schema; the decode is lenient.
//

import Foundation
import os

/// How one of the five is called. Pure, so the requests can be tested
/// without a network.
public nonisolated enum CompatibleProvider {
    public static let deepseekModel = "deepseek-flash"
    public static let gigachatModel = "GigaChat/GigaChat-3-Pro"
    public static let yandexModel = "aliceai-llm"
    public static let geminiModel = "gemini-3.8-flash"
    public static let grokModel = "grok-4.3"

    static func handles(_ kind: SummaryProviderKind) -> Bool {
        switch kind {
        case .deepseek, .gigachat, .yandex, .gemini, .grok: true
        case .anthropic, .openai, .kimi: false
        }
    }

    /// The request for a reply to `messages` under `system`. `maxTokens`
    /// is the answer's budget; a model that thinks inside the same
    /// limit (Gemini) gets room for both.
    public static func request(
        kind: SummaryProviderKind,
        apiKey: String,
        folderID: String? = nil,
        system: String,
        messages: [CloudText.Message],
        maxTokens: Int
    ) throws -> URLRequest {
        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any]
        var request: URLRequest
        switch kind {
        case .grok:
            // Responses API; `store: false` so a meeting is not kept for
            // a later turn. grok-4.3 can stop reasoning.
            request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
            body = [
                "model": grokModel,
                "instructions": system,
                "input": turns,
                "store": false,
                "max_output_tokens": maxTokens,
                "reasoning": ["effort": "none"],
            ]
        case .yandex:
            guard let folder = YandexFolder.normalized(folderID ?? "") else {
                throw SummaryProviderError.missingAPIKey(provider: kind.displayName)
            }
            request = URLRequest(url: URL(string: "https://ai.api.cloud.yandex.net/v1/chat/completions")!)
            request.setValue(folder, forHTTPHeaderField: "OpenAI-Project")
            // Yandex logs requests unless told not to.
            request.setValue("false", forHTTPHeaderField: "x-data-logging-enabled")
            body = ["model": "gpt://\(folder)/\(yandexModel)", "max_tokens": maxTokens]
        case .deepseek:
            request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
            // Thinking is on by default and billed; a summary gains little.
            body = ["model": deepseekModel, "thinking": ["type": "disabled"], "max_tokens": maxTokens]
        case .gigachat:
            request = URLRequest(url: URL(string: "https://foundation-models.api.cloud.ru/v1/chat/completions")!)
            body = ["model": gigachatModel, "max_tokens": maxTokens]
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!)
            // The limit includes the thinking; no temperature for Gemini 3.
            body = ["model": geminiModel, "reasoning_effort": "low", "max_tokens": max(maxTokens * 2, 8192)]
        case .anthropic, .openai, .kimi:
            throw SummaryProviderError.invalidResponse(provider: kind.displayName)
        }
        if kind != .grok {
            body["messages"] = [["role": "system", "content": system]] + turns
        }
        request.httpMethod = "POST"
        request.setValue(kind == .yandex ? "Api-Key \(apiKey)" : "Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The answer's text: `choices[0].message.content`, or for Grok the
    /// `output_text` parts of the `message` items (reasoning items are
    /// never the answer).
    public static func replyText(_ json: [String: Any], kind: SummaryProviderKind) throws -> String {
        let provider = kind.displayName
        let text: String
        if kind == .grok {
            let items = json["output"] as? [[String: Any]] ?? []
            text = items.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
        } else {
            text = try CloudSummaryCall.chatContent(json, provider: provider)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryProviderError.invalidResponse(provider: provider) }
        return trimmed
    }

    static func complete(kind: SummaryProviderKind, apiKey: String, system: String,
                         messages: [CloudText.Message], maxTokens: Int, log: Logger) async throws -> String {
        let request = try request(kind: kind, apiKey: apiKey, folderID: YandexFolder.current,
                                  system: system, messages: messages, maxTokens: maxTokens)
        let json = try await CloudSummaryCall.send(request, provider: kind.displayName, log: log)
        return try replyText(json, kind: kind)
    }
}

/// YandexGPT needs a folder ID besides the key. The Mac keeps it in its
/// own preferences, which don't reach the phone, so it is typed here
/// (Settings → Summary). A future Mac version may put it in the shared
/// keychain under `SecretKey.yandexFolderID`; that wins when present.
public nonisolated enum YandexFolder {
    public static let defaultsKey = "daisy.yandexFolderID"

    public static var current: String? {
        if let synced = KeychainStore.get(account: SecretKey.yandexFolderID), let folder = normalized(synced) {
            return folder
        }
        return normalized(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    /// As the Mac's `YandexAPISummarizer.normalizedFolderID`: trims, takes
    /// the folder out of a pasted `gpt://<folder>/<model>`, and refuses
    /// anything but ASCII letters and digits (a Cyrillic look-alike
    /// typed on the Russian layout would fail at Yandex).
    public static func normalized(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("gpt://") {
            value = String(value.dropFirst("gpt://".count).prefix { $0 != "/" })
        }
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return value
    }
}

/// The summary through one of the five: the same prompt pair and decode
/// as the others.
public nonisolated struct CompatibleSummaryProvider: SummaryProvider {
    public let kind: SummaryProviderKind
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "CompatibleSummarizer")

    public init(kind: SummaryProviderKind) { self.kind = kind }

    public func summarize(transcript: String, title: String, localeHint: String?, singleVoice: Bool = false) async throws -> MeetingSummary {
        let provider = kind.displayName
        let (text, apiKey) = try CloudSummaryCall.prepare(transcript: transcript, keyAccount: kind.keyAccount, provider: provider)
        // 8192: what a long meeting's summary needed on the Mac.
        let reply = try await CompatibleProvider.complete(
            kind: kind, apiKey: apiKey,
            system: SummaryPrompt.meetingSystemInstructions(localeHint: localeHint, singleVoice: singleVoice),
            messages: [.init(role: .user, text: SummaryPrompt.meetingUserPrompt(title: title, transcript: text))],
            maxTokens: 8192, log: log)
        return try CloudSummaryCall.decode(reply, provider: provider)
    }
}
