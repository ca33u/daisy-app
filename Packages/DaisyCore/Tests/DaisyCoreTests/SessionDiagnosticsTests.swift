//
//  SessionDiagnosticsTests.swift
//  DaisyCoreTests
//
//  backlog 4 B-4: `daisy_diag_*` keys survive render → Mac parser →
//  parse, sit before `tags` (the contract's last key), and never touch
//  the keys the contract defines.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Session diagnostics in frontmatter")
struct SessionDiagnosticsTests {
    @Test func diagnosticsRoundTripAndKeepTagsLast() {
        var d = SessionDiagnostics()
        d.batteryStart = 0.87
        d.batteryStop = 0.8
        d.thermalStart = "nominal"
        d.thermalStop = "fair"
        d.startedInBackground = true
        d.queueWaitSec = 42
        d.transcribeSec = 7

        var fm = SessionFrontmatter.phoneRecording(
            title: "Field test", started: Date(timeIntervalSince1970: 1_000_000), duration: 61.9, micBytes: 1234
        )
        fm.extras = d.fields()
        let text = fm.render() + "\n\nbody\n"

        let parsed = SessionDocument.parseFrontmatter(in: text)
        #expect(parsed.keyOrder.last == "tags")
        #expect(parsed.keyOrder.firstIndex(of: SessionDiagnostics.Key.batteryStart)! < parsed.keyOrder.firstIndex(of: "tags")!)
        #expect(parsed.durationSec == 61)

        let back = SessionDiagnostics.parse(parsed)
        #expect(back == d)

        let reparsed = SessionFrontmatter.parse(text)
        #expect(reparsed?.extras == d.fields())
    }

    @Test func emptyDiagnosticsWriteNothing() {
        let fm = SessionFrontmatter.phoneRecording(title: "t", started: Date(), duration: 30, micBytes: 10)
        #expect(!fm.render().contains("daisy_diag_"))
        #expect(SessionDiagnostics().isEmpty)
    }
}
