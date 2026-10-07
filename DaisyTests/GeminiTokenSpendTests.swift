//
//  GeminiTokenSpendTests.swift
//  DaisyTests
//
//  Gemini bills thinking as output, and its OpenAI-compatible usage
//  object has been seen carrying those tokens outside
//  `completion_tokens`. The ledger must count them either way.
//

import Testing
@testable import Daisy

@Suite("Gemini token spend")
struct GeminiTokenSpendTests {
    @Test("thinking only in total_tokens is still counted")
    func thinkingInTotal() {
        let json: [String: Any] = ["usage": ["prompt_tokens": 1000, "completion_tokens": 200, "total_tokens": 1700]]
        #expect(TokenSpend.geminiCompatible(from: json).outputTokens == 700)
    }

    @Test("thinking in reasoning_tokens is added once")
    func thinkingInDetails() {
        let json: [String: Any] = ["usage": [
            "prompt_tokens": 1000, "completion_tokens": 200, "total_tokens": 1700,
            "completion_tokens_details": ["reasoning_tokens": 500],
        ]]
        #expect(TokenSpend.geminiCompatible(from: json).outputTokens == 700)
    }

    @Test("when completion already includes thinking, nothing is doubled")
    func thinkingInsideCompletion() {
        let json: [String: Any] = ["usage": [
            "prompt_tokens": 1000, "completion_tokens": 700, "total_tokens": 1700,
            "completion_tokens_details": ["reasoning_tokens": 500],
        ]]
        let spend = TokenSpend.geminiCompatible(from: json)
        #expect(spend.outputTokens == 700)
        #expect(spend.inputTokens == 1000)
    }
}
