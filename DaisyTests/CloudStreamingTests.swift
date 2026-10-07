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
/// was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
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
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Cloud summary streaming", .serialized)
struct CloudStreamingTests {
    private func session(_ responses: [(Int, String)]) -> URLSession {
        StubProtocol.responses = responses.map { (status: $0.0, body: $0.1) }
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
}
