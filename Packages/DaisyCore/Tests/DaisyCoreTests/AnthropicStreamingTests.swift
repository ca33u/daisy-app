//
//  AnthropicStreamingTests.swift
//  DaisyCoreTests
//
//  The phone's Anthropic call streams (2026-10-08): a thinking-only or
//  cut-off reply is its own error, not an empty summary, and the
//  request carries room for thinking plus the answer.
//

import Foundation
import Testing
@testable import DaisyCore

struct AnthropicStreamingTests {
    private func feed(_ events: [String]) -> AnthropicStreamAccumulator {
        var acc = AnthropicStreamAccumulator()
        for event in events { acc.consume(event) }
        return acc
    }

    @Test func textAfterThinking() {
        let acc = feed([
            #"{"type":"message_start","message":{"usage":{"input_tokens":30000}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"summary\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\"ok\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":900}}"#,
        ])
        #expect(acc.text == #"{"summary":"ok"}"#)
        #expect(acc.stopReason == "end_turn")
        #expect(acc.blockTypes == ["thinking", "text"])
    }

    @Test func thinkingOnlyIsCutOff() {
        let acc = feed([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ])
        #expect(acc.text.isEmpty)
        #expect(acc.stopReason == "max_tokens")
    }

    @Test func midStreamError() {
        let acc = feed([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        #expect(acc.streamError == "Overloaded")
    }

    @Test func bodyHasRoomForThinking() {
        let modern = AnthropicStreaming.body(model: "claude-sonnet-5-5", maxTokens: 4096, effort: "medium",
                                             system: "s", messages: [])
        #expect(modern["max_tokens"] as? Int == 64_000)
        #expect(modern["stream"] as? Bool == true)
        #expect((modern["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(AnthropicStreaming.isModern("claude-haiku-5-5"))

        let haiku45 = AnthropicStreaming.body(model: "claude-haiku-4-5-20251001", maxTokens: 4096, effort: "medium",
                                              system: "s", messages: [])
        #expect(haiku45["max_tokens"] as? Int == 32_000)
        #expect(haiku45["output_config"] == nil)
    }
}
