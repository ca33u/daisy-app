//
//  SessionEditingTests.swift
//  DaisyCoreTests
//
//  backlog 8 G-2: an edit replaces the transcript section only; the
//  frontmatter is carried over byte for byte; the title is one line.
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
        try SessionEditing.save(transcript: "**[0:00 · Me]** hello there\n\n**[0:05 · Me]** world", to: tmp)
        let out = try String(contentsOf: tmp, encoding: .utf8)
        #expect(SessionEditing.split(out).frontmatter == SessionEditing.split(file).frontmatter)
        #expect(out.contains("# T\n\n> recorded now · 0:10"))
        #expect(SessionEditing.transcriptText(in: SessionEditing.split(out).body) == "**[0:00 · Me]** hello there\n\n**[0:05 · Me]** world")
        #expect(SessionDocument.parseFrontmatter(in: out).title == "T")
    }

    @Test func sectionReplacementLeavesOtherSectionsAlone() {
        let body = SessionEditing.split(file).body + "\n## Shared on screen\n\nOCR text\n"
        let edited = SessionEditing.setSection(TranscriptDocument.transcriptHeading, to: "**[0:00 · Me]** changed", in: body)
        #expect(SessionEditing.transcriptText(in: edited) == "**[0:00 · Me]** changed")
        #expect(SessionEditing.section("## Shared on screen", in: edited)?.trimmingCharacters(in: .whitespacesAndNewlines) == "OCR text")
        #expect(edited.hasPrefix("\n# T\n\n> recorded now · 0:10"))
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
