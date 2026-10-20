//
//  SessionDiagnosticsLogTests.swift
//  DaisyTests
//
//  B-3 (20.10): a recording keeps its own os_log excerpt in its folder,
//  because the report's Info lines roll out of logd within minutes. The
//  pure parts — the window, the cap, the compact line layout, the merge
//  that keeps the header — are checked here without logd.
//

import Foundation
import OSLog
import Testing
@testable import Daisy

struct SessionDiagnosticsLogTests {
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Window

    @Test func theFirstCaptureReachesAMinuteBeforeRecord() {
        #expect(DiagnosticsLog.leadIn == 60)
        // No cursor yet: the requested window stands.
        #expect(DiagnosticsLog.captureStart(cursor: nil, requested: started.addingTimeInterval(-60)) == started.addingTimeInterval(-60))
    }

    @Test func aLaterCaptureStartsWhereTheLastOneEnded() {
        let cursor = started.addingTimeInterval(300)
        // Finalize asks from the moment Stop captured; the cursor Stop
        // left is later and wins, so nothing is appended twice — and
        // had Stop's capture failed (no cursor), finalize's window would
        // still start at Stop, not at finalize's own end.
        #expect(DiagnosticsLog.captureStart(cursor: cursor, requested: started.addingTimeInterval(290)) == cursor)
        #expect(DiagnosticsLog.captureStart(cursor: nil, requested: started.addingTimeInterval(290)) == started.addingTimeInterval(290))
        // A queue job asks from its own start, before the cursor: the
        // cursor wins, so Stop's lines aren't appended a second time.
        #expect(DiagnosticsLog.captureStart(cursor: cursor, requested: started) == cursor)
    }

    @Test func anEntryBelongsToTheHalfOpenWindow() {
        let after = started
        let until = started.addingTimeInterval(10)
        #expect(!DiagnosticsLog.includes(entryDate: after, after: after, until: until))
        #expect(DiagnosticsLog.includes(entryDate: after.addingTimeInterval(0.001), after: after, until: until))
        #expect(DiagnosticsLog.includes(entryDate: until, after: after, until: until))
        #expect(!DiagnosticsLog.includes(entryDate: until.addingTimeInterval(0.001), after: after, until: until))
    }

    @Test func capturesComeMoreOftenThanTheInfoRingLasted() {
        // User log A's Mac kept about 13 minutes of Info lines.
        #expect(DiagnosticsLog.captureInterval <= 600)
    }

    // MARK: Line layout

    @Test func aLineReadsLikeTheReportsCompactStyle() {
        let line = DiagnosticsLog.line(
            date: started, levelTag: "I", process: "Daisy", pid: 49731, tid: 0x167af4e,
            subsystem: "app.essazanov.Daisy", category: "Whisper", message: "Whisper pass done <private>"
        )
        #expect(line.hasSuffix(" I  Daisy[49731:167af4e] [app.essazanov.Daisy:Whisper] Whisper pass done <private>"))
        #expect(line.hasPrefix(DiagnosticsLog.timestamp(started)))
        // The type column is two wide, then one space — "Df Daisy", "I  Daisy".
        let notice = DiagnosticsLog.line(
            date: started, levelTag: "Df", process: "Daisy", pid: 1, tid: 1,
            subsystem: "s", category: "c", message: "m"
        )
        #expect(notice.contains(" Df Daisy[1:1] [s:c] m"))
    }

    @Test func levelTagsMatchLogShow() {
        #expect(DiagnosticsLog.levelTag(.debug) == "Db")
        #expect(DiagnosticsLog.levelTag(.info) == "I")
        #expect(DiagnosticsLog.levelTag(.notice) == "Df")
        #expect(DiagnosticsLog.levelTag(.error) == "E")
        #expect(DiagnosticsLog.levelTag(.fault) == "F")
    }

    @Test func theTimestampHasMilliseconds() {
        let text = DiagnosticsLog.timestamp(started.addingTimeInterval(0.396))
        #expect(text.count == "2026-10-19 12:59:55.396".count)
        #expect(text.hasSuffix(".396"))
    }

    // MARK: Merge and cap

    @Test func aNewFileGetsTheHeaderAndTheLines() {
        let header = DiagnosticsLog.header(recordingStartedAt: started, appVersion: "1.0.8.33 (150)")
        let text = DiagnosticsLog.merged(existing: nil, header: header, newLines: ["a", "b"])
        #expect(text == header + "\na\nb\n")
        #expect(header.hasPrefix(DiagnosticsLog.headerPrefix))
        #expect(header.contains("1.0.8.33 (150)"))
    }

    @Test func anAppendKeepsTheExistingHeader() {
        let first = DiagnosticsLog.header(recordingStartedAt: started, appVersion: "1")
        let existing = first + "\na\n"
        let later = DiagnosticsLog.header(recordingStartedAt: started.addingTimeInterval(3600), appVersion: "2")
        let text = DiagnosticsLog.merged(existing: existing, header: later, newLines: ["b"])
        #expect(text == first + "\na\nb\n")
    }

    @Test func aFileWithoutAHeaderGetsOne() {
        let header = DiagnosticsLog.header(recordingStartedAt: started, appVersion: "1")
        let text = DiagnosticsLog.merged(existing: "a", header: header, newLines: ["b"])
        #expect(text == header + "\na\nb\n")
    }

    @Test func nothingNewLeavesTheFileAsItWas() {
        let header = DiagnosticsLog.header(recordingStartedAt: started, appVersion: "1")
        let existing = header + "\na\n"
        #expect(DiagnosticsLog.merged(existing: existing, header: header, newLines: []) == existing)
    }

    @Test func theCapKeepsTheNewestLinesWhole() {
        let body = (0..<1000).map { "line \($0) with some padding to make it longer" }.joined(separator: "\n") + "\n"
        let trimmed = DiagnosticsLog.trimmedTail(body, maxBytes: 2000)
        #expect(trimmed.hasPrefix("(trimmed to the most recent 0 MB)\n"))
        #expect(trimmed.hasSuffix("line 999 with some padding to make it longer\n"))
        // Cut at a line boundary: the first kept line is a whole one.
        let firstKept = trimmed.split(separator: "\n")[1]
        #expect(firstKept.hasPrefix("line "))
        #expect(trimmed.utf8.count <= 2000 + "(trimmed to the most recent 0 MB)\n".utf8.count)
    }

    @Test func underTheCapNothingIsTrimmed() {
        #expect(DiagnosticsLog.trimmedTail("a\nb\n", maxBytes: 2000) == "a\nb\n")
        #expect(DiagnosticsLog.maxBytes == 2_000_000)
    }

    @Test func theCapAppliesToTheBodyNotTheHeader() {
        let header = DiagnosticsLog.header(recordingStartedAt: started, appVersion: "1")
        let lines = (0..<40_000).map { "line \($0) ................................................" }
        let text = DiagnosticsLog.merged(existing: nil, header: header, newLines: lines)
        #expect(text.hasPrefix(header + "\n(trimmed to the most recent 2 MB)\n"))
        #expect(text.hasSuffix("line 39999 ................................................\n"))
        #expect(text.utf8.count <= header.utf8.count + 1 + DiagnosticsLog.maxBytes + 40)
    }
}
