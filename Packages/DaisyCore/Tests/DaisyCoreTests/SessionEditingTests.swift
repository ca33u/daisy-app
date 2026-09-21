//
//  SessionEditingTests.swift
//  DaisyCoreTests
//
//  backlog 8 G-2: edits replace one section, the frontmatter is carried
//  over byte for byte, a pending note survives the finishing pass.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Session editing (§7.2 / §7.3)")
struct SessionEditingTests {
    private let file = """
    ---
    title: "T"
    daisy_kind: recording
    daisy_speaker_map: {}
    tags: [meeting, transcript, daisy]
    ---

    # T

    > recorded now · 0:10

    ## Transcript

    **[0:00 · Me]** hello

    **[0:05 · Me]** world
    """

    @Test func transcriptEditKeepsFrontmatterAndTitleLine() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).md")
        try file.write(to: tmp, atomically: true, encoding: .utf8)
        try SessionEditing.save(transcript: "**[0:00 · Me]** hello there\n\n**[0:05 · Me]** world", notes: nil, to: tmp)
        let out = try String(contentsOf: tmp, encoding: .utf8)
        #expect(SessionEditing.split(out).frontmatter == SessionEditing.split(file).frontmatter)
        #expect(out.contains("# T\n\n> recorded now · 0:10"))
        #expect(SessionEditing.transcriptText(in: SessionEditing.split(out).body) == "**[0:00 · Me]** hello there\n\n**[0:05 · Me]** world")
        #expect(SessionDocument.parseFrontmatter(in: out).title == "T")
    }

    @Test func notesAreASectionBeforeTheTranscript() throws {
        let body = SessionEditing.split(file).body
        let withNotes = SessionEditing.setSection(SessionEditing.notesHeading, to: "call Maria\nsend the deck", in: body)
        #expect(SessionEditing.notes(in: withNotes) == "call Maria\nsend the deck")
        let notesAt = withNotes.range(of: "## Notes")!.lowerBound
        let transcriptAt = withNotes.range(of: "## Transcript")!.lowerBound
        #expect(notesAt < transcriptAt)
        #expect(SessionEditing.transcriptText(in: withNotes) == "**[0:00 · Me]** hello\n\n**[0:05 · Me]** world")
        // Replace, then remove.
        let replaced = SessionEditing.setSection(SessionEditing.notesHeading, to: "only this", in: withNotes)
        #expect(SessionEditing.notes(in: replaced) == "only this")
        #expect(replaced.components(separatedBy: "## Notes").count == 2)
        let removed = SessionEditing.setSection(SessionEditing.notesHeading, to: "", in: replaced)
        #expect(SessionEditing.notes(in: removed) == nil)
        #expect(SessionEditing.transcriptText(in: removed) == "**[0:00 · Me]** hello\n\n**[0:05 · Me]** world")
    }

    @Test func pendingNoteSurvivesTheFinishingPass() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionEditing.savePendingNotes("written while transcribing", in: dir)
        #expect(SessionEditing.pendingNotes(in: dir) == "written while transcribing")
        try SessionWriter.finish(directory: dir, transcript: file)
        let out = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(SessionEditing.notes(in: SessionEditing.split(out).body) == "written while transcribing")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SessionEditing.pendingNotesName).path))
        #expect(SessionDocument.parseFrontmatter(in: out).title == "T")
    }

    @Test func titleChangesOneLine() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString).md")
        try file.write(to: tmp, atomically: true, encoding: .utf8)
        try SessionEditing.saveTitle("Ask \"Roman\"", to: tmp)
        let out = try String(contentsOf: tmp, encoding: .utf8)
        #expect(out.contains("title: \"Ask \\\"Roman\\\"\""))
        // The Mac's reader strips the quotes and nothing else (§3.1, the
        // listed gap) — the phone reads the same file the same way.
        #expect(SessionDocument.parseFrontmatter(in: out).title == "Ask \\\"Roman\\\"")
        #expect(SessionDocument.yamlUnquote("\"Ask \\\"Roman\\\"\"") == "Ask \"Roman\"")
        #expect(SessionEditing.split(out).body == SessionEditing.split(file).body)
    }
}
