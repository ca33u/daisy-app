//
//  CloudStreamingTests.swift
//  DaisyTests
//
//  The cloud summarizers stream (07.10.2026). A user's two-hour meeting
//  failed on Anthropic: thinking used the whole 4096-token allowance and
//  the reply had no text, then a cut-off reply failed to parse. These
//  run the real summarizers against a stubbed server on a synthetic
//  two-hour transcript — no network, no key.
//

import Foundation
import Testing
@testable import Daisy

/// Serves one canned response per request, in order, and records what
/// was asked. A negative status fails the request with that `URLError`
/// code before any response (−1001 timed out, −999 cancelled);
/// `failAfterBody` fails the next successful one after its body, as a
/// stream that breaks off mid-answer.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var failAfterBody: URLError.Code?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        // URLProtocol sees the body as a stream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            Self.bodies.append(data)
        } else {
            Self.bodies.append(request.httpBody ?? Data())
        }
        let next: (status: Int, body: String) = Self.responses.isEmpty ? (status: 500, body: "no stub") : Self.responses.removeFirst()
        if next.status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: next.status)))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        if let code = Self.failAfterBody {
            Self.failAfterBody = nil
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Cloud summary streaming", .serialized)
struct CloudStreamingTests {
    private func session(_ responses: [(Int, String)]) -> URLSession {
        StubProtocol.responses = responses.map { (status: $0.0, body: $0.1) }
        StubProtocol.failAfterBody = nil
        StubProtocol.requests = []
        StubProtocol.bodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    /// Two hours of conversation, a line every ~6 s.
    private let twoHourTranscript: String = (0..<1200).map { i in
        let minute = i / 10, second = (i % 10) * 6
        let speaker = i % 3 == 0 ? "Me" : (i % 3 == 1 ? "Remote A" : "Remote B")
        return String(format: "**[%d:%02d · %@]** ", minute, second, speaker)
            + "We went through the launch plan, the budget and who owns the next step for item \(i)."
    }.joined(separator: "\n\n")

    private let summaryJSON = #"{"summary":"Launch plan agreed.","sections":[{"title":"Plan","bullets":[{"text":"Ship in May","children":[]}]}],"actionItems":["Anna: send the budget"],"clientFollowUp":""}"#

    /// An Anthropic SSE body: a thinking block, the JSON split into
    /// deltas, then the stop reason.
    private func anthropicSSE(text: String, stop: String) -> String {
        func event(_ name: String, _ data: [String: Any]) -> String {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            return "event: \(name)\ndata: \(json)\n\n"
        }
        var out = event("message_start", ["type": "message_start",
                                          "message": ["usage": ["input_tokens": 30_000, "output_tokens": 1]]])
        out += event("content_block_start", ["type": "content_block_start", "index": 0,
                                             "content_block": ["type": "thinking", "thinking": ""]])
        out += "event: ping\ndata: {\"type\":\"ping\"}\n\n"
        out += event("content_block_stop", ["type": "content_block_stop", "index": 0])
        if !text.isEmpty {
            out += event("content_block_start", ["type": "content_block_start", "index": 1,
                                                 "content_block": ["type": "text", "text": ""]])
            var rest = Substring(text)
            while !rest.isEmpty {
                let piece = rest.prefix(17)
                rest = rest.dropFirst(17)
                out += event("content_block_delta", ["type": "content_block_delta", "index": 1,
                                                     "delta": ["type": "text_delta", "text": String(piece)]])
            }
        }
        out += event("message_delta", ["type": "message_delta", "delta": ["stop_reason": stop],
                                       "usage": ["output_tokens": 2_500]])
        out += event("message_stop", ["type": "message_stop"])
        return out
    }

    private func requestJSON(_ index: Int = 0) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies[index]) as? [String: Any])
    }

    @Test("Anthropic: a two-hour meeting streams, with room to think")
    func anthropicTwoHours() async throws {
        let s = session([(200, anthropicSSE(text: summaryJSON, stop: "end_turn"))])
        let summary = try await AnthropicAPISummarizer(urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        #expect(summary.summary == "Launch plan agreed.")
        #expect(summary.actionItems == ["Anna: send the budget"])
        let body = try requestJSON()
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 64_000)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(StubProtocol.requests.first?.timeoutInterval == CloudStreaming.idleTimeout)
    }

    @Test("Anthropic: thinking that used the whole limit is reported as cut off, not as a bad response")
    func anthropicThinkingOnly() async throws {
        let s = session([(200, anthropicSSE(text: "", stop: "max_tokens"))])
        await #expect(throws: SummaryProviderError.self) {
            _ = try await AnthropicAPISummarizer(urlSession: s, apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        }
        do {
            _ = try await AnthropicAPISummarizer(urlSession: session([(200, anthropicSSE(text: "{\"summary\":\"cut", stop: "max_tokens"))]), apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
            Issue.record("expected outputTruncated")
        } catch SummaryProviderError.outputTruncated {
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Anthropic: an overloaded server is retried before the answer starts")
    func anthropicRetriesBeforeStart() async throws {
        let s = session([(529, #"{"type":"error","error":{"type":"overloaded_error"}}"#),
                         (200, anthropicSSE(text: summaryJSON, stop: "end_turn"))])
        let summary = try await AnthropicAPISummarizer(urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        #expect(summary.summary == "Launch plan agreed.")
        #expect(StubProtocol.requests.count == 2)
    }

    @Test("Anthropic: an error event mid-stream is reported, not retried")
    func anthropicMidStreamError() async throws {
        let body = anthropicSSE(text: "", stop: "end_turn")
            .replacingOccurrences(of: "event: message_stop", with: "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\nevent: message_stop")
        let s = session([(200, body), (200, anthropicSSE(text: summaryJSON, stop: "end_turn"))])
        do {
            _ = try await AnthropicAPISummarizer(urlSession: s, apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
            Issue.record("expected streamInterrupted")
        } catch SummaryProviderError.streamInterrupted {
            #expect(StubProtocol.requests.count == 1)
        }
    }

    @Test("OpenAI: streams with usage, and a length stop is reported as cut off")
    func openAI() async throws {
        func sse(_ content: String, finish: String) -> String {
            var out = ""
            var rest = Substring(content)
            while !rest.isEmpty {
                let piece = rest.prefix(20); rest = rest.dropFirst(20)
                let chunk = ["choices": [["index": 0, "delta": ["content": String(piece)]]]]
                out += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
            }
            out += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\n"
            out += "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":30000,\"completion_tokens\":900}}\n\n"
            out += "data: [DONE]\n\n"
            return out
        }
        let s = session([(200, sse(summaryJSON, finish: "stop"))])
        let summary = try await OpenAIAPISummarizer(urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        #expect(summary.summary == "Launch plan agreed.")
        let body = try requestJSON()
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

        do {
            _ = try await OpenAIAPISummarizer(urlSession: session([(200, sse("{\"summary\":\"cut", finish: "length"))]), apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
            Issue.record("expected outputTruncated")
        } catch SummaryProviderError.outputTruncated {
        }
    }

    @Test("Anthropic usage: a null in message_delta never wipes the input count")
    func usageNullSafe() {
        var acc = AnthropicStreamAccumulator()
        acc.consume(#"{"type":"message_start","message":{"usage":{"input_tokens":30000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        acc.consume(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":null,"output_tokens":2500}}"#)
        #expect(acc.messageJSON["usage"].flatMap { ($0 as? [String: Any])?["input_tokens"] as? Int } == 30000)
        #expect(acc.messageJSON["usage"].flatMap { ($0 as? [String: Any])?["output_tokens"] as? Int } == 2500)
        #expect(acc.stopReason == "end_turn")
    }

    @Test("Anthropic: a custom older model keeps the old ceiling and gets no effort")
    func olderModel() async throws {
        let s = session([(200, anthropicSSE(text: summaryJSON, stop: "end_turn"))])
        _ = try await AnthropicAPISummarizer(model: "claude-3-7-sonnet-latest", urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        let body = try requestJSON()
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["output_config"] == nil)
    }

    /// OpenAI-shaped SSE: content deltas, a finish chunk, then usage —
    /// top-level (`usageInChoice: false`) or inside the choice (Moonshot).
    private func openAISSE(_ content: String, finish: String, usageInChoice: Bool = false) -> String {
        var out = ""
        var rest = Substring(content)
        while !rest.isEmpty {
            let piece = rest.prefix(20); rest = rest.dropFirst(20)
            let chunk = ["choices": [["index": 0, "delta": ["content": String(piece)]]]]
            out += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        if usageInChoice {
            out += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\",\"usage\":{\"prompt_tokens\":30000,\"completion_tokens\":900}}]}\n\n"
        } else {
            out += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\n"
            out += "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":30000,\"completion_tokens\":900}}\n\n"
        }
        return out + "data: [DONE]\n\n"
    }

    @Test("Gemini streams, and a length stop is reported as cut off")
    func gemini() async throws {
        let s = session([(200, openAISSE(summaryJSON, finish: "stop"))])
        let summary = try await GeminiAPISummarizer(urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        #expect(summary.summary == "Launch plan agreed.")
        let body = try requestJSON()
        #expect(body["stream"] as? Bool == true)
        #expect(StubProtocol.requests.first?.timeoutInterval == 300)
        do {
            _ = try await GeminiAPISummarizer(urlSession: session([(200, openAISSE("{\"summary\":\"cut", finish: "length"))]), apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
            Issue.record("expected outputTruncated")
        } catch SummaryProviderError.outputTruncated {
        }
    }

    @Test("Kimi streams, with usage inside the final choice")
    func kimi() async throws {
        let s = session([(200, openAISSE(summaryJSON, finish: "stop", usageInChoice: true))])
        let summary = try await KimiAPISummarizer(urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        #expect(summary.summary == "Launch plan agreed.")
        #expect(try requestJSON()["stream"] as? Bool == true)
        var acc = OpenAIStreamAccumulator()
        for line in openAISSE("x", finish: "stop", usageInChoice: true).split(separator: "\n") where line.hasPrefix("data:") {
            acc.consume(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
        #expect(acc.usage?["prompt_tokens"] as? Int == 30000)
    }

    @Test("Kimi requests carry no temperature — every current model rejects one")
    func kimiParameters() async throws {
        func body(_ model: String) async throws -> [String: Any] {
            let s = session([(200, openAISSE(summaryJSON, finish: "stop"))])
            _ = try await KimiAPISummarizer(model: model, urlSession: s, apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
            return try requestJSON()
        }
        let k26 = try await body("kimi-k2.6")
        #expect(k26["temperature"] == nil && k26["max_tokens"] == nil)
        #expect((k26["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(k26["max_completion_tokens"] as? Int == 8192)
        let k3 = try await body("kimi-k3")
        #expect(k3["temperature"] == nil && k3["thinking"] == nil)
        #expect(k3["reasoning_effort"] as? String == "low")
        let code = try await body("kimi-k2.7-code")
        #expect(code["temperature"] == nil && code["thinking"] == nil && code["reasoning_effort"] == nil)
        #expect(code["max_completion_tokens"] as? Int == 16_384)
    }

    @Test("OpenAI reasoning models are asked for low reasoning effort")
    func openAIReasoningEffort() async throws {
        let s = session([(200, openAISSE(summaryJSON, finish: "stop"))])
        _ = try await OpenAIAPISummarizer(model: "gpt-5.6-terra", urlSession: s, apiKeyOverride: "test")
            .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
        #expect(try requestJSON()["reasoning_effort"] as? String == "low")
    }

    // MARK: - YandexGPT (27.10.2026)

    /// No usage chunk: these runs must not add spend to the real token
    /// ledger (`TokenLedger.shared` writes UserDefaults.standard).
    private func yandexSSE(_ content: String, finish: String) -> String {
        var out = ""
        var rest = Substring(content)
        while !rest.isEmpty {
            let piece = rest.prefix(20); rest = rest.dropFirst(20)
            let chunk = ["choices": [["index": 0, "delta": ["content": String(piece)]]]]
            out += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        out += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\n"
        return out + "data: [DONE]\n\n"
    }

    private func yandex(_ responses: [(Int, String)], model: String = YandexAPISummarizer.defaultModelID,
                        folder: String = "b1gtest", transcript: String? = nil) async throws -> MeetingSummary {
        try await YandexAPISummarizer(model: model, folderID: folder, urlSession: session(responses), apiKeyOverride: "AQVNtest")
            .summarize(transcript: transcript ?? twoHourTranscript, title: "Launch", localeHint: "ru", task: .meeting(forceFollowUp: false))
    }

    @Test("YandexGPT: key, folder and no-logging header on the request; only documented parameters")
    func yandexRequest() async throws {
        let summary = try await yandex([(200, yandexSSE(summaryJSON, finish: "stop"))])
        #expect(summary.summary == "Launch plan agreed.")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url == YandexAPISummarizer.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Api-Key AQVNtest")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "b1gtest")
        #expect(request.value(forHTTPHeaderField: "x-data-logging-enabled") == "false")
        #expect(request.timeoutInterval == 300)
        let body = try requestJSON()
        #expect(body["model"] as? String == "gpt://b1gtest/aliceai-llm")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 8192)
        for unsent in ["temperature", "response_format", "max_completion_tokens", "reasoning_effort", "thinking"] {
            #expect(body[unsent] == nil, "\(unsent)")
        }
    }

    @Test("YandexGPT: a refused stream_options is dropped and the request sent once more")
    func yandexStreamOptionsFallback() async throws {
        let refusal = #"{"error":{"message":"Unknown field: stream_options","type":"invalid_request_error"}}"#
        let summary = try await yandex([(400, refusal), (200, yandexSSE(summaryJSON, finish: "stop"))])
        #expect(summary.summary == "Launch plan agreed.")
        #expect(StubProtocol.requests.count == 2)
        #expect(try requestJSON(0)["stream_options"] != nil)
        #expect(try requestJSON(1)["stream_options"] == nil)
    }

    @Test("YandexGPT: a length stop is cut off; a bad key and a retired model say so in words")
    func yandexErrors() async throws {
        do {
            _ = try await yandex([(200, yandexSSE("{\"summary\":\"cut", finish: "length"))])
            Issue.record("expected outputTruncated")
        } catch SummaryProviderError.outputTruncated {
        }
        do {
            _ = try await yandex([(401, #"{"error":{"message":"Failed to authenticate","type":"authentication_error"}}"#)])
            Issue.record("expected the key message")
        } catch SummaryProviderError.modelUnavailable(_, let reason) {
            #expect(reason.contains("folder ID") || reason.contains("ID каталога"))
        }
        #expect(StubProtocol.requests.count == 1, "a 401 is not retried")
        do {
            _ = try await yandex([(400, #"{"error":{"message":"Model gpt://b1gtest/aliceai-llm not found"}}"#)])
            Issue.record("expected the retired-model message")
        } catch SummaryProviderError.modelUnavailable(_, let reason) {
            #expect(reason.contains("aliceai-llm"))
        }
        #expect(StubProtocol.requests.count == 1, "a 400 is not retried")
        // A refusal that names stream_options AND the model is still the
        // stream_options case, not a retirement.
        let both = YandexAPISummarizer.worded(status: 400, body: "unknown parameter stream_options for model aliceai-llm", model: "aliceai-llm")
        guard case .httpError(_, 400, _) = both else { Issue.record("\(both)"); return }
    }

    @Test("A timeout before the answer is not retried and says no answer came; mid-answer it says the model stalled")
    func timeouts() async throws {
        do {
            _ = try await yandex([(-1001, ""), (200, yandexSSE(summaryJSON, finish: "stop"))])
            Issue.record("expected a timeout")
        } catch let error as SummaryProviderError {
            guard case .timedOut(_, 300, false) = error else { Issue.record("\(error)"); return }
            #expect(error.localizedDescription.contains("couldn’t get an answer") || error.localizedDescription.contains("не удалось получить ответ"))
        }
        #expect(StubProtocol.requests.count == 1, "a timeout may still be generating — a retry would bill it twice")

        do {
            let s = session([(200, yandexSSE("{\"summary\":\"Launch", finish: "stop").components(separatedBy: "\n\n").first! + "\n\n")])
            StubProtocol.failAfterBody = .timedOut
            _ = try await YandexAPISummarizer(folderID: "b1gtest", urlSession: s, apiKeyOverride: "AQVNtest")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "ru", task: .meeting(forceFollowUp: false))
            Issue.record("expected a stall")
        } catch let error as SummaryProviderError {
            guard case .timedOut(_, 300, true) = error else { Issue.record("\(error)"); return }
            #expect(error.localizedDescription.contains("faster model") || error.localizedDescription.contains("побыстрее"))
        }
        // A connection that never opened is still retried.
        _ = try await yandex([(-1004, ""), (200, yandexSSE(summaryJSON, finish: "stop"))])
        #expect(StubProtocol.requests.count == 2)
    }

    @Test("A withdrawn summary is CancellationError — opening, mid-stream, on every OpenAI-compatible path")
    func cancellation() async throws {
        do {
            _ = try await yandex([(-999, "")])
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        }
        #expect(StubProtocol.requests.count == 1)
        do {
            let s = session([(200, yandexSSE("{\"summary\":\"x", finish: "stop").components(separatedBy: "\n\n").first! + "\n\n")])
            StubProtocol.failAfterBody = .cancelled
            _ = try await KimiAPISummarizer(urlSession: s, apiKeyOverride: "test")
                .summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "en", task: .meeting(forceFollowUp: false))
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        }
    }

    @Test("YandexGPT: no folder ID — not ready, and nothing is sent")
    func yandexNeedsFolder() async throws {
        let provider = YandexAPISummarizer(folderID: "  ", urlSession: session([]), apiKeyOverride: "AQVNtest")
        #expect(await provider.isReady() == false)
        do {
            _ = try await provider.summarize(transcript: twoHourTranscript, title: "Launch", localeHint: "ru", task: .meeting(forceFollowUp: false))
            Issue.record("expected the folder message")
        } catch SummaryProviderError.modelUnavailable {
        }
        #expect(StubProtocol.requests.isEmpty)
        #expect(await YandexAPISummarizer(folderID: "b1gtest", apiKeyOverride: "AQVNtest").isReady())
    }

    @Test("YandexGPT: a meeting longer than the model's window is refused before anything is sent")
    func yandexContextWindow() async throws {
        // ~386K characters ≈ 128.6K tokens at 3 per token, plus the
        // system prompt: past Alice's 131,072 less the 8,192-token answer.
        let long = String(repeating: twoHourTranscript + "\n\n", count: 3)
        #expect(LocalContextGuard.estimatedTokens(promptChars: long.count) > 131_072 - 8192)
        do {
            _ = try await yandex([], transcript: long)
            Issue.record("expected a refusal")
        } catch SummaryProviderError.modelUnavailable(_, let reason) {
            #expect(reason.contains("Alice AI LLM") && !reason.contains("recommended") && !reason.contains("рекоменд"))
            // Digits only: the number is grouped for the reader («122,880»).
            #expect(reason.filter(\.isNumber).contains("\(131_072 - 8192)"), "the room is the window less the answer: \(reason)")
            #expect(reason.contains("DeepSeek V4.1 Flash"))
        }
        #expect(StubProtocol.requests.isEmpty)
        // Past even DeepSeek's 1M: no suggestion to pick what is picked.
        let huge = String(repeating: twoHourTranscript + "\n\n", count: 25)
        do {
            _ = try await yandex([], model: "deepseek-v4.1-flash", transcript: huge)
            Issue.record("expected a refusal")
        } catch SummaryProviderError.modelUnavailable(_, let reason) {
            #expect(!reason.contains("Pick") && !reason.contains("Выбери"), "\(reason)")
        }
        // DeepSeek's 1M takes the three-copy meeting.
        _ = try await yandex([(200, yandexSSE(summaryJSON, finish: "stop"))], model: "deepseek-v4.1-flash", transcript: long)
        #expect(try requestJSON()["max_tokens"] as? Int == 16_384)
    }
}

/// The parts of the YandexGPT provider that need no network.
struct YandexProviderTests {
    @Test func folderIDIsCleanedAndAWholeURIAccepted() {
        #expect(YandexAPISummarizer.normalizedFolderID(" b1g4abc5def \n") == "b1g4abc5def")
        #expect(YandexAPISummarizer.normalizedFolderID("gpt://b1g4abc/aliceai-llm") == "b1g4abc")
        #expect(YandexAPISummarizer.normalizedFolderID("") == nil)
        #expect(YandexAPISummarizer.normalizedFolderID("b1g abc") == nil)
        #expect(YandexAPISummarizer.normalizedFolderID("gpt:///aliceai-llm") == nil)
    }

    @Test func retiredModelsMoveOnAndOthersStay() {
        #expect(YandexAPISummarizer.resolvedModelID("yandexgpt-5-lite") == "aliceai-llm")
        #expect(YandexAPISummarizer.resolvedModelID("gpt-oss-120b") == "aliceai-llm")
        #expect(YandexAPISummarizer.resolvedModelID("deepseek-v4-flash") == "deepseek-v4.1-flash")
        #expect(YandexAPISummarizer.resolvedModelID("gpt://b1g/qwen3.6-35b-a3b") == "qwen3.6-35b-a3b")
        #expect(YandexAPISummarizer.resolvedModelID("my-own-model") == "my-own-model")
        #expect(YandexAPISummarizer.resolvedModelID("  ") == "aliceai-llm")
        for model in YandexAPISummarizer.availableModels.map(\.id) {
            #expect(YandexAPISummarizer.resolvedModelID(model) == model)
            #expect(YandexAPISummarizer.contextTokens(for: model) != nil, "\(model)")
        }
    }

    @Test func httpFailuresInWords() {
        let busy = YandexAPISummarizer.worded(status: 429, body: "", model: "aliceai-llm")
        guard case .modelUnavailable = busy else { Issue.record("429: \(busy)"); return }
        // A 400 about a limit that mentions the model is not a retirement.
        let limit = YandexAPISummarizer.worded(status: 400, body: "max_tokens exceeds the model limit", model: "aliceai-llm")
        guard case .httpError(_, 400, _) = limit else { Issue.record("limit: \(limit)"); return }
        let server = YandexAPISummarizer.worded(status: 500, body: "oops", model: "aliceai-llm")
        guard case .httpError(_, 500, _) = server else { Issue.record("500: \(server)"); return }
    }

    @Test func yandexIsACloudProviderEverywhere() {
        #expect(!SummaryProviderKind.yandex.isLocal)
        #expect(SummaryProviderKind.yandex.requiresAPIKey)
        #expect(TokenLedger.isBilled(.yandex))
        // No country (Egor, 27.10) — in English or Russian.
        for word in ["Russia", "Росс", "РФ"] {
            #expect(!SummaryProviderKind.yandex.privacyTag.localizedCaseInsensitiveContains(word))
        }
    }

    @Test func aTimeoutReadsAsATimeout() {
        var request = URLRequest(url: YandexAPISummarizer.endpoint)
        request.timeoutInterval = 300
        let worded = CloudStreaming.timeoutWorded(URLError(.timedOut), provider: "YandexGPT", request: request, midAnswer: true)
        guard case SummaryProviderError.timedOut(_, 300, true)? = worded as? SummaryProviderError else {
            Issue.record("\(worded)"); return
        }
        #expect(worded.localizedDescription.contains("5 min") || worded.localizedDescription.contains("5 мин"))
        let other = CloudStreaming.timeoutWorded(URLError(.notConnectedToInternet), provider: "YandexGPT", request: request, midAnswer: false)
        #expect((other as? URLError)?.code == .notConnectedToInternet)
    }

    @Test func folderIDIsASCIIOnly() {
        // «b1g» with a Cyrillic «с» and «о» typed on the Russian layout.
        #expect(YandexAPISummarizer.normalizedFolderID("b1gсоde") == nil)
        #expect(YandexAPISummarizer.normalizedFolderID("b1gcode") == "b1gcode")
    }

    @Test func stream_optionsRefusalIsRecognisedHoweverWritten() {
        for body in ["Unknown field: stream_options", "STREAM_OPTIONS is not supported", "unknown field streamOptions",
                     "include_usage: unsupported"] {
            #expect(YandexAPISummarizer.refusesStreamOptions(body), "\(body)")
        }
        #expect(!YandexAPISummarizer.refusesStreamOptions("messages array cannot be empty"))
    }

    @Test func aStoredRetiredModelIsWrittenBack() throws {
        let suite = "daisy.tests.yandexModel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(YandexAPISummarizer.storedModelID(key: "daisy.yandexModel", defaults: defaults) == "aliceai-llm")
        #expect(defaults.string(forKey: "daisy.yandexModel") == nil, "nothing stored, nothing written")
        defaults.set("yandexgpt-5-lite", forKey: "daisy.yandexModel")
        #expect(YandexAPISummarizer.storedModelID(key: "daisy.yandexModel", defaults: defaults) == "aliceai-llm")
        #expect(defaults.string(forKey: "daisy.yandexModel") == "aliceai-llm")
        defaults.set("qwen3.6-35b-a3b", forKey: "daisy.yandexModel")
        #expect(YandexAPISummarizer.storedModelID(key: "daisy.yandexModel", defaults: defaults) == "qwen3.6-35b-a3b")
    }

    @Test func pricesMatchExactIDsOnly() {
        let spend = TokenSpend(inputTokens: 1_000_000, outputTokens: 0)
        #expect(TokenCostEstimator.estimate(provider: .yandex, model: "aliceai-llm", spend: spend).hasPricedUsage)
        #expect(!TokenCostEstimator.estimate(provider: .yandex, model: "aliceai-llm-flash", spend: spend).hasPricedUsage)
    }

    /// No country in the UI (Egor, 27.10) — read from the catalog, so the
    /// Russian is checked too, whatever language the test host runs in.
    @Test func noCountryInEitherLanguage() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        let keys = strings.keys.filter { $0.contains("Yandex") || $0.contains("YandexGPT") }
        #expect(keys.count >= 4)
        for key in keys {
            let ru = (((strings[key]?["localizations"] as? [String: Any])?["ru"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(ru != nil, "no Russian for \(key)")
            for word in ["Russia", "Росс", "РФ"] {
                #expect(!key.localizedCaseInsensitiveContains(word), "\(key)")
                #expect(!(ru ?? "").localizedCaseInsensitiveContains(word), "\(key)")
            }
        }
    }

    @MainActor
    @Test func theDaisyKeyStartsWithoutCloudAccessForYandex() throws {
        // A fresh install's prefs: no grant until the person says yes.
        let suite = "daisy.tests.daisyKeyCloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!DaisyKeyController.cloudAllowed(.yandex, defaults: defaults))
        defaults.set(true, forKey: "daisy.daisyKey.cloudAllowed.yandex")
        #expect(DaisyKeyController.cloudAllowed(.yandex, defaults: defaults), "the grant is per provider, under its raw value")
    }

    @Test func aLatestBranchIsTheSameModel() {
        let model = YandexAPISummarizer.resolvedModelID("gpt://b1g/aliceai-llm/latest")
        #expect(model == "aliceai-llm/latest")
        #expect(YandexAPISummarizer.contextTokens(for: model) == 131_072)
        #expect(YandexAPISummarizer.answerTokens(for: model) == 8192)
        #expect(YandexAPISummarizer.plainName(for: model) == "Alice AI LLM")
        let spend = TokenSpend(inputTokens: 1_000_000, outputTokens: 0)
        #expect(TokenCostEstimator.estimate(provider: .yandex, model: model, spend: spend).hasPricedUsage)
        #expect(YandexAPISummarizer.resolvedModelID("gpt-oss-120b/latest") == "aliceai-llm")
        #expect(YandexAPISummarizer.resolvedModelID("yandexgpt-5-lite/latest@ft123") == "yandexgpt-5-lite/latest@ft123")
    }
}

/// `reasoning_effort: "low"` only where the model takes it — a 400 would
/// cost the summary (review find, 08.10.2026).
struct ReasoningEffortModelTests {
    @Test func lowEffortOnlyWhereAccepted() {
        for id in ["gpt-5.6-terra", "gpt-5-mini", "o3", "o4-mini", "o1"] {
            #expect(OpenAIAPISummarizer.takesLowReasoningEffort(id), "\(id)")
        }
        for id in ["gpt-5-pro", "gpt-5-chat-latest", "o1-mini", "o1-preview", "gpt-4o"] {
            #expect(!OpenAIAPISummarizer.takesLowReasoningEffort(id), "\(id)")
        }
    }
}
