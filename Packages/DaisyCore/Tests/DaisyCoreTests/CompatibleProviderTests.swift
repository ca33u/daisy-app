import Foundation
import Testing
@testable import DaisyCore

/// The five providers ported to the phone on 04.11: each request goes
/// where the Mac's adapter sends it, signed the way that provider wants.
@Suite("Compatible providers (04.11)")
struct CompatibleProviderTests {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    private func request(_ kind: SummaryProviderKind, folder: String? = nil) throws -> URLRequest {
        try CompatibleProvider.request(kind: kind, apiKey: "k", folderID: folder, system: "sys",
                                       messages: [.init(role: .user, text: "hi")], maxTokens: 1000)
    }

    @Test func deepseekGoesToDeepSeekWithThinkingOff() throws {
        let r = try request(.deepseek)
        #expect(r.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let b = try body(r)
        #expect(b["model"] as? String == "deepseek-flash")
        #expect((b["thinking"] as? [String: String])?["type"] == "disabled")
        let messages = try #require(b["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(b["response_format"] == nil)
    }

    @Test func gigachatGoesThroughCloudRu() throws {
        let r = try request(.gigachat)
        #expect(r.url?.host == "foundation-models.api.cloud.ru")
        #expect(try body(r)["model"] as? String == "GigaChat/GigaChat-3-Pro")
    }

    @Test func yandexCarriesTheFolderAndAsksNotToLog() throws {
        let r = try request(.yandex, folder: " gpt://b1gabc123/aliceai-llm ")
        #expect(r.url?.absoluteString == "https://ai.api.cloud.yandex.net/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Api-Key k")
        #expect(r.value(forHTTPHeaderField: "OpenAI-Project") == "b1gabc123")
        #expect(r.value(forHTTPHeaderField: "x-data-logging-enabled") == "false")
        #expect(try body(r)["model"] as? String == "gpt://b1gabc123/aliceai-llm")
    }

    @Test func yandexWithoutAFolderIsNotSent() {
        #expect(throws: SummaryProviderError.self) { try request(.yandex, folder: nil) }
        // Cyrillic «с» typed on the Russian layout.
        #expect(YandexFolder.normalized("b1gс") == nil)
        #expect(YandexFolder.normalized("") == nil)
    }

    @Test func geminiGetsRoomToThink() throws {
        let b = try body(request(.gemini))
        #expect(b["model"] as? String == "gemini-3.8-flash")
        #expect(b["reasoning_effort"] as? String == "low")
        #expect(b["max_tokens"] as? Int == 8192)
    }

    @Test func grokUsesTheResponsesAPIAndIsNotStored() throws {
        let r = try request(.grok)
        #expect(r.url?.absoluteString == "https://api.x.ai/v1/responses")
        let b = try body(r)
        #expect(b["instructions"] as? String == "sys")
        #expect(b["store"] as? Bool == false)
        #expect(b["max_output_tokens"] as? Int == 1000)
        #expect(b["messages"] == nil)
        #expect((b["input"] as? [[String: String]])?.first?["content"] == "hi")
    }

    @Test func groksAnswerIsTheMessageNotTheReasoning() throws {
        let json: [String: Any] = ["output": [
            ["type": "reasoning", "summary": [["type": "summary_text", "text": "thinking"]]],
            ["type": "message", "content": [["type": "output_text", "text": "{\"a\":1}"]]],
        ]]
        #expect(try CompatibleProvider.replyText(json, kind: .grok) == "{\"a\":1}")
        #expect(throws: SummaryProviderError.self) { try CompatibleProvider.replyText(["output": []], kind: .grok) }
    }

    @Test func chatReplyIsTheFirstChoice() throws {
        let json: [String: Any] = ["choices": [["message": ["content": " ok "]]]]
        #expect(try CompatibleProvider.replyText(json, kind: .deepseek) == "ok")
    }

    @Test func rawValuesMatchTheMac() {
        #expect(SummaryProviderKind.allCases.map(\.rawValue)
                == ["anthropic", "openai", "kimi", "deepseek", "gigachat", "yandex", "gemini", "grok"])
        #expect(SummaryProviderKind.yandex.keyAccount == "yandex.api_key")
        #expect(SummaryProviderKind.gigachat.keyAccount == "gigachat.api_key")
    }

    private func reason(_ kind: SummaryProviderKind, _ status: Int, _ body: String = "") -> String? {
        guard case .unavailable(_, let reason) = CompatibleProvider.worded(kind: kind, status: status, body: body) else { return nil }
        return reason
    }

    @Test func refusalsSayWhatToDo() {
        #expect(reason(.deepseek, 402)?.contains("platform.deepseek.com") == true)
        #expect(reason(.gigachat, 403, #"{"message":"Insufficient balance"}"#)?.contains("console.cloud.ru") == true)
        #expect(reason(.grok, 403, "Your team has run out of credits")?.contains("console.x.ai") == true)
        // A bad key: on the Mac, where keys are entered.
        #expect(reason(.deepseek, 401, "Authentication Fails")?.contains("on the Mac") == true)
        #expect(reason(.gigachat, 400, "invalid api key secret")?.contains("on the Mac") == true)
        #expect(reason(.gemini, 400, "API key not valid. Please pass a valid API key.")?.contains("on the Mac") == true)
        #expect(reason(.yandex, 401)?.contains("folder ID") == true)
        #expect(reason(.deepseek, 400, "Model Not Exist")?.contains("DeepSeek Flash") == true)
        #expect(reason(.grok, 400, "This model's maximum context length is 1000000 tokens")?.contains("longer than") == true)
        #expect(reason(.yandex, 429)?.contains("two at a time") == true)
        // Nothing to say: the status stays.
        #expect(reason(.gemini, 500) == nil)
        #expect(reason(.gigachat, 400, "max_tokens is too large") == nil)
    }
}
