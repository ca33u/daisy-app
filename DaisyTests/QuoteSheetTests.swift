// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  QuoteSheetTests.swift
//  DaisyTests
//
//  Backlog 24 М-11 on the Mac: the transcript's lines, read for a quote.
//

import DaisyCore
import Foundation
import Testing
@testable import Daisy

@Suite("Quote on the Mac")
struct QuoteSheetTests {
    @Test func theTranscriptsLinesAreReadWithTheirTimesAndSpeakers() {
        let transcript = "**[0:05 · Anna]** Morning.\n\n**[1:02:10 · Boris]** The price is final.\n\nnot a line"
        let lines = QuoteSheet.segments(in: transcript)
        #expect(lines.count == 2)
        #expect(lines[0].speaker == "Anna")
        #expect(lines[1].startSec == 3730)
        #expect(lines[1].text == "The price is final.")
    }
}
