//
//  AskPromptTests.swift
//  DaisyCoreTests
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Ask prompt")
struct AskPromptTests {
    @Test func materialCarriesNumberedMeetingsAndStampedPieces() {
        let sources = [AskPrompt.Source(number: 1, title: "Vet", date: "2026-09-21", summary: "Dog check-up.",
                                        pieces: [(860, "The lump is a cyst.")])]
        let text = AskPrompt.user(question: "What did the vet say?", sources: sources, today: "2026-09-28")
        #expect(text.contains("=== Meeting 1: Vet — 2026-09-21 ==="))
        #expect(text.contains("[1 · 14:20]\nThe lump is a cyst."))
        #expect(text.hasSuffix("Question: What did the vet say?"))
    }

    @Test func fittingKeepsTheBestAndStaysUnderTheCeiling() {
        let long = String(repeating: "слово ", count: 2000)
        let sources = (1...8).map { AskPrompt.Source(number: $0, title: "M\($0)", date: "d", summary: long,
                                                    pieces: (0..<6).map { (Double($0 * 40), long) }) }
        let fitted = AskPrompt.fitted(sources, limit: 30_000)
        #expect(fitted.first?.number == 1)
        let size = fitted.reduce(0) { $0 + ($1.summary?.count ?? 0) + $1.pieces.reduce(0) { $0 + $1.1.count } }
        #expect(size <= 30_000)
    }

    @Test func clockReadsLikeTheTranscript() {
        #expect(AskPrompt.clock(75) == "1:15")
        #expect(AskPrompt.clock(3725) == "1:02:05")
    }
}
