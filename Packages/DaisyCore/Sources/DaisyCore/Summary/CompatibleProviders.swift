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
        let json: [String: Any]
        do {
            json = try await CloudSummaryCall.send(request, provider: kind.displayName, log: log)
        } catch SummaryProviderError.httpError(_, let status, let body) {
            throw worded(kind: kind, status: status, body: body)
        }
        return try replyText(json, kind: kind)
    }

    /// The HTTP failures a person can do something about, in words — the
    /// Mac adapters' `worded`, with the phone's own advice: keys are
    /// entered on the Mac, there is no model picker here. The rest keep
    /// the status. 429 and 5xx arrive here only after the retries.
    static func worded(kind: SummaryProviderKind, status: Int, body: String) -> SummaryProviderError {
        let provider = kind.displayName
        let lowered = body.lowercased()
        let model = modelName(kind)
        func say(_ reason: String) -> SummaryProviderError { .unavailable(provider: provider, reason: reason) }

        let moneyWords = ["insufficient balance", "insufficient funds", "insufficient_balance", "insufficient_funds",
                          "credit", "spending limit", "баланс", "недостаточно средств"]
        if status == 402 || ((status == 403 || status == 429) && moneyWords.contains { lowered.contains($0) }) {
            switch kind {
            case .deepseek: return say(String(localized: "the balance has run out. Top it up at platform.deepseek.com and try again."))
            case .gigachat: return say(String(localized: "the cloud.ru balance has run out. Top it up at console.cloud.ru and try again."))
            case .grok: return say(String(localized: "your xAI team is out of credits or at its spending limit. Top up at console.x.ai and try again."))
            default: return say(String(localized: "the account's balance has run out. Top it up with the provider and try again."))
            }
        }
        // cloud.ru answers a bad key with 400 «invalid api key secret».
        let keyRefused = status == 401 || status == 403
            || (status == 400 && (lowered.contains("api key") || lowered.contains("api_key") || lowered.contains("authorization")))
        if keyRefused {
            if kind == .yandex {
                return say(String(localized: "the API key or the folder ID wasn’t accepted. Check the key in Daisy on the Mac and the folder ID in Profile → Summary provider."))
            }
            return say(String(localized: "the API key wasn’t accepted. Check it in Daisy on the Mac; it comes to this phone through iCloud Keychain."))
        }
        if status == 429 {
            if kind == .yandex {
                return say(String(localized: "too many requests — an account without a subscription runs two at a time. Try again in a minute."))
            }
            return say(String(localized: "too many requests. Try again in a minute."))
        }
        if lowered.contains("context length") || lowered.contains("maximum context")
            || lowered.contains("prompt is too long") || lowered.contains("prompt length") {
            return say(String(localized: "this meeting is longer than \(model) can read."))
        }
        let modelMissing = lowered.contains("model not exist") || lowered.contains("model_uri") || lowered.contains("model uri")
            || (lowered.contains("model") && ["not found", "does not exist", "unknown", "deprecated", "retired"].contains { lowered.contains($0) })
        if status == 404 || (status == 400 && modelMissing) {
            return say(String(localized: "no model \(model) — the provider may have retired it. Update Daisy from the App Store."))
        }
        return .httpError(provider: provider, status: status, body: body)
    }

    static func modelName(_ kind: SummaryProviderKind) -> String {
        switch kind {
        case .deepseek: "DeepSeek Flash"
        case .gigachat: "GigaChat-3-Pro"
        case .yandex: "Alice AI LLM"
        case .gemini: "Gemini 3.8 Flash"
        case .grok: "Grok 4.3"
        case .anthropic, .openai, .kimi: kind.displayName
        }
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
