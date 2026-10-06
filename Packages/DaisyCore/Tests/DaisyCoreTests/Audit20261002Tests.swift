//
//  Audit20261002Tests.swift
//  DaisyCoreTests
//
//  The DaisyLite audit of 2026-10-02: each fix that lives in DaisyCore,
//  held by a test. A quoted title round-trips (§3.1); a pasted line break
//  cannot split the frontmatter; a rebuilt summary keeps what was done
//  with its steps; a session over the screenshot budget is pushed once,
//  not on every pass.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Audit 2026-10-02 — session files")
struct AuditSessionFileTests {
    private func file(titleLine: String) -> String {
        "---\n\(titleLine)\ndaisy_kind: recording\ndaisy_speaker_map: {}\n---\n\n# T\n\n## Transcript\n\n**[0:00 · Me]** hello\n"
    }

    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aQuotedTitleComesBackAsItWasTyped() throws {
        let url = try write(file(titleLine: "title: \"T\""))
        let title = #"Q3 "final" C:\plan"#
        try SessionEditing.saveTitle(title, to: url)
        let once = try String(contentsOf: url, encoding: .utf8)
        #expect(SessionDocument.parseFrontmatter(in: once).title == title)
        // Saved again as read: the line on disk does not grow.
        try SessionEditing.saveTitle(SessionDocument.parseFrontmatter(in: once).title ?? "", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == once)
    }

    @Test func aBackslashThatEscapesNothingIsKept() {
        #expect(SessionDocument.unescaped(#"a\b"#) == #"a\b"#)
        #expect(SessionDocument.unescaped(#"a\\b \"c\""#) == #"a\b "c""#)
        #expect(SessionDocument.unescaped(#"tail\"#) == #"tail\"#)
    }

    @Test func aPastedLineBreakStaysInsideTheTitle() throws {
        let url = try write(file(titleLine: "title: \"T\""))
        try SessionEditing.saveTitle("one\n---\ntwo", to: url)
        let parsed = SessionDocument.parseFrontmatter(in: try String(contentsOf: url, encoding: .utf8))
        #expect(parsed.title == "one --- two")
        #expect(parsed.kind == "recording")
        #expect(parsed.body.contains("**[0:00 · Me]** hello"))
    }

    @Test func aNamedSpeakerWithAQuoteRoundTrips() {
        let line = SessionDocument.yamlInlineDict(["A": #"Alex "Sasha" K"#])
        #expect(SessionDocument.parseYAMLDict(line)["A"] == #"Alex "Sasha" K"#)
    }
}

@Suite("Audit 2026-10-02 — a rebuilt summary")
struct AuditSummaryRebuildTests {
    @Test func stepsKeepWhatWasDoneWithThem() {
        let done = ActionItem.Status(state: .scheduled, destination: "reminders", identifier: "R-1")
        let old = MeetingSummary(summary: "s", actionItems: ["a", "b", "c"], clientFollowUp: "", actions: [
            ActionItem(id: "1", text: "Send the contract to Boris", status: done),
            ActionItem(id: "2", text: "Book a room", status: .init(state: .done, destination: "manual")),
            ActionItem(id: "3", text: "Call the bank"),
        ])
        let rebuilt = MeetingSummary(summary: "s2", actionItems: ["x", "y", "z"], clientFollowUp: "", actions: [
            ActionItem(id: "9", text: "send the contract to Boris "),
            ActionItem(id: "8", text: "Book the room for Monday"),
            ActionItem(id: "7", text: "Write the release notes"),
        ]).carryingStatuses(from: old) { $0.hasPrefix("Book") && $1.hasPrefix("Book") }
        #expect(rebuilt.actions[0].status?.identifier == "R-1")
        #expect(rebuilt.actions[1].status?.state == .done)
        #expect(rebuilt.actions[2].status == nil)
    }

    @Test func oneOldStepIsGivenAwayOnce() {
        let old = MeetingSummary(summary: "s", actionItems: ["a"], clientFollowUp: "", actions: [
            ActionItem(id: "1", text: "Call Anna", status: .init(state: .done, destination: "manual")),
        ])
        let rebuilt = MeetingSummary(summary: "s", actionItems: ["a", "b"], clientFollowUp: "", actions: [
            ActionItem(id: "5", text: "Call Anna"),
            ActionItem(id: "6", text: "Call Anna"),
        ]).carryingStatuses(from: old) { _, _ in true }
        #expect(rebuilt.actions.filter { $0.status != nil }.count == 1)
    }
}

@MainActor
@Suite("Audit 2026-10-02 — sync")
struct AuditSyncTests {
    @Test func aSessionOverTheScreenshotBudgetIsPushedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-sync-\(UUID().uuidString)", isDirectory: true)
        let base = SessionsBase(base: root)
        let id = "2026-10-02T10-00-00Z"
        let dir = base.sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        let shots = dir.appendingPathComponent(SyncPolicy.screenshotsDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try "---\ntitle: \"Frames\"\ndaisy_kind: recording\ndaisy_speaker_map: {}\n---\n\n# T\n\n## Transcript\n\n**[0:00 · Me]** hello\n"
            .write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        // Three frames of 9 MB: the third does not fit in the 20 MB budget.
        for n in 1...3 {
            try Data(repeating: UInt8(n), count: 9 * 1_048_576).write(to: shots.appendingPathComponent(String(format: "%03d.jpg", n)))
        }
        let engine = SessionSyncEngine(base: base, stateURL: root.appendingPathComponent("sync-state.json"), transport: InMemorySyncTransport())
        let first = try await engine.syncOnce()
        #expect(first.pushed == 1)
        let second = try await engine.syncOnce()
        #expect(second.pushed == 0)
    }

    @Test func anEmptyRemoteBodyNeverReplacesATranscript() async throws {
        let cloud = InMemorySyncTransport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-sync-\(UUID().uuidString)", isDirectory: true)
        let base = SessionsBase(base: root)
        let id = "2026-10-02T11-00-00Z"
        let dir = base.sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.md")
        try "---\ntitle: \"Kept\"\ndaisy_kind: recording\ndaisy_speaker_map: {}\n---\n\n# T\n\n## Transcript\n\n**[0:00 · Me]** hello\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let engine = SessionSyncEngine(base: base, stateURL: root.appendingPathComponent("sync-state.json"), transport: cloud)
        _ = try await engine.syncOnce()
        // The other side's record arrives with its body missing.
        var broken = try #require(try engine.snapshot(of: id))
        broken.body = ""
        broken.bodyStamp = Date().timeIntervalSince1970 + 60
        broken.editor = "another-device"
        try await cloud.push([broken])
        _ = try await engine.syncOnce()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("**[0:00 · Me]** hello"))
    }
}

@Suite("Audit 2026-10-02 — small things")
struct AuditSmallThingsTests {
    @Test func aDayIsWrittenAndReadInTheSameTimeZone() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        // Half past midnight, local: the GMT day may be yesterday.
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 0, minute: 30)))
        #expect(ActionItem.day(date) == "2026-10-02")
        let back = try #require(ActionItem.date(from: ActionItem.day(date)))
        #expect(calendar.isDate(back, inSameDayAs: date))
    }

    @Test func leftoverStagingIsRemovedAndSessionsStay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-sweep-\(UUID().uuidString)", isDirectory: true)
        let base = SessionsBase(base: root)
        let sessions = try base.ensureSessionsDirectory()
        for name in [".daisy-import-A", ".daisy-sync-B", ".daisy-watch-C", ".daisy-recording-2026-10-02T10-00-00Z", ".daisy-trash", "2026-10-02T09-00-00Z"] {
            try FileManager.default.createDirectory(at: sessions.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(SessionWriter.sweepTransient(in: base) == 3)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: sessions.path))
        #expect(left == [".daisy-recording-2026-10-02T10-00-00Z", ".daisy-trash", "2026-10-02T09-00-00Z"])
    }

    @Test func aKeyRemovedOnOneSideIsRemovedOnTheOther() async throws {
        let cloud = InMemorySyncTransport()
        func device(_ name: String) throws -> (base: SessionsBase, engine: SessionSyncEngine) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-rm-\(name)-\(UUID().uuidString)", isDirectory: true)
            let base = SessionsBase(base: root)
            try FileManager.default.createDirectory(at: base.sessionsDirectory, withIntermediateDirectories: true)
            return (base, SessionSyncEngine(base: base, stateURL: root.appendingPathComponent("sync-state.json"), transport: cloud))
        }
        let phone = try device("phone"), mac = try device("mac")
        let id = "2026-10-06T10-00-00Z"
        let dir = phone.base.sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.md")
        try "---\ntitle: \"Take\"\ndaisy_kind: rehearsal\ndaisy_best_take: true\ndaisy_speaker_map: {}\n---\n\n# T\n\n## Transcript\n\n**[0:00 · Me]** hello\n"
            .write(to: url, atomically: true, encoding: .utf8)
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        let macURL = mac.base.sessionsDirectory.appendingPathComponent("\(id)/transcript.md")
        #expect(try String(contentsOf: macURL, encoding: .utf8).contains("daisy_best_take: true"))
        // The phone takes «best» off; file mtimes are the stamps.
        try await Task.sleep(for: .milliseconds(1100))
        let without = SessionDocument.removingFrontmatter(in: try String(contentsOf: url, encoding: .utf8), key: "daisy_best_take")
        try without.write(to: url, atomically: true, encoding: .utf8)
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        #expect(!(try String(contentsOf: macURL, encoding: .utf8)).contains("daisy_best_take"))
        // And it does not come back to the phone on the next round.
        _ = try await mac.engine.syncOnce()
        _ = try await phone.engine.syncOnce()
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("daisy_best_take"))
    }
}

@Suite("A meeting longer than the model's window")
struct LongTranscriptTests {
    @Test func partsCutBetweenSegmentsAndLoseNothing() {
        let segments = (0..<400).map { "**[\($0):00 · Me]** " + String(repeating: "слово ", count: 60) }
        let transcript = segments.joined(separator: "\n\n")
        #expect(LongTranscript.needsParts(transcript) == (transcript.count > LongTranscript.threshold))
        let parts = LongTranscript.parts(of: transcript, limit: 20_000)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= 20_000 })
        #expect(parts.joined(separator: "\n\n") == transcript)
        #expect(parts.allSatisfy { $0.hasPrefix("**[") })
    }

    @Test func aSingleHugeParagraphIsStillCut() {
        let huge = String(repeating: "x", count: 50_000)
        let parts = LongTranscript.parts(of: huge, limit: 20_000)
        #expect(parts.count == 3)
        #expect(parts.joined() == huge)
    }

    @Test func theDigestKeepsTheOrderAndTheSteps() {
        let a = MeetingSummary(summary: "First hour.", sections: [SummarySection(title: "Pricing", bullets: [SummaryBullet(text: "Agreed 10%", children: [])])], actionItems: ["Anna: send the draft"], clientFollowUp: "")
        let b = MeetingSummary(summary: "Second hour.", actionItems: [], clientFollowUp: "")
        let digest = LongTranscript.digest(of: [a, b])
        #expect(digest.range(of: "Part 1 of 2")!.lowerBound < digest.range(of: "Part 2 of 2")!.lowerBound)
        #expect(digest.contains("- Agreed 10%"))
        #expect(digest.contains("- Anna: send the draft"))
        #expect(digest.contains("Second hour."))
    }
}

@Suite("The scan's cache")
struct SessionScanCacheTests {
    @Test func anUnchangedFolderIsNotReadAgainAndAChangedOneIs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        let base = SessionsBase(base: root)
        let sessions = try base.ensureSessionsDirectory()
        let dir = sessions.appendingPathComponent("2026-10-06T09-00-00Z", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.md")
        try "---\ntitle: \"One\"\ndaisy_kind: recording\n---\n\n## Transcript\n\n**[0:00 · Me]** a\n".write(to: url, atomically: true, encoding: .utf8)
        let cache = SessionScanCache()
        #expect(SessionClassifier.scan(base: base, cache: cache).first?.title == "One")
        // Rewritten behind the cache's back within the same second: the
        // stale title is what the cache is allowed to answer.
        try await Task.sleep(for: .milliseconds(1100))
        try "---\ntitle: \"Two\"\ndaisy_kind: recording\n---\n\n## Transcript\n\n**[0:00 · Me]** a\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(SessionClassifier.scan(base: base, cache: cache).first?.title == "Two")
        try FileManager.default.removeItem(at: dir)
        #expect(SessionClassifier.scan(base: base, cache: cache).isEmpty)
        #expect(cache.entries.isEmpty)
    }
}
