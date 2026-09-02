//
//  ReliabilityAuditTests.swift
//  DaisyTests
//
//  Pins the fixes from the 2026-09-01 reliability audit that can be
//  exercised without a device. Each test names the failure it guards
//  against, so a future regression reads as "the audit bug is back",
//  not as an abstract assertion.
//

import Foundation
import Testing
@testable import Daisy

// MARK: - Privacy filter round-trip (P0: placeholders leaking into text)

@Suite("Privacy placeholders never reach the person")
struct PrivacyPlaceholderTests {

    @Test("Restore tolerates the token shapes models actually return")
    func restore_isTolerantToModelMangling() {
        let originals = ["[[DAISY_PERSON_001]]": "Алексей", "[[DAISY_EMAIL_001]]": "a@b.io"]
        // Verbatim, lowercased, spaced inside the brackets, spaced
        // around the underscores — all seen in the field.
        let mangled = "Звонил [[DAISY_PERSON_001]], потом [[ daisy_person_001 ]] написал на [[DAISY _ EMAIL _ 001]]."
        let restored = SensitiveDataProtector.restore(mangled, using: originals)
        #expect(restored == "Звонил Алексей, потом Алексей написал на a@b.io.")
        #expect(!SensitiveDataProtector.containsUnrestoredMarker(restored))
    }

    @Test("Restore is a no-op on text without tokens")
    func restore_leavesPlainTextAlone() {
        let text = "Ничего защищённого здесь нет, даже [[скобок]] в другом смысле."
        #expect(SensitiveDataProtector.restore(text, using: ["[[DAISY_PERSON_001]]": "x"]) == text)
    }

    @Test("Unrestored markers are detected in any shape")
    func marker_detection() {
        #expect(SensitiveDataProtector.containsUnrestoredMarker("see [[DAISY_PERSON_001]]"))
        #expect(SensitiveDataProtector.containsUnrestoredMarker("see [[ redacted_email ]]"))
        #expect(SensitiveDataProtector.containsUnrestoredMarker("[[Daisy_Phone_002]] called"))
        #expect(!SensitiveDataProtector.containsUnrestoredMarker("a normal sentence"))
        #expect(!SensitiveDataProtector.containsUnrestoredMarker("markdown [[link]] is fine"))
    }

    @Test("Polish tasks pseudonymise secrets reversibly instead of redacting them")
    func polish_usesReversibleTokensForEverything() {
        let input = "use api_key=supersecretvalue and the card 4111 1111 1111 1111"
        let protected = SensitiveDataProtector.protect(
            transcript: input,
            title: "Dictation",
            task: .dictationPolish(instruction: ""),
            detectNamedEntities: false
        )
        // Nothing sensitive on the wire…
        #expect(!protected.transcript.contains("supersecretvalue"))
        #expect(!protected.transcript.contains("4111 1111 1111 1111"))
        // …and nothing irreversible either: every entity has a way back.
        #expect(!protected.transcript.contains("[[REDACTED_"))
        #expect(protected.report.redactedOccurrences == 0)
        let echoed = MeetingSummary(
            summary: "", sections: [], actionItems: [], clientFollowUp: protected.transcript
        )
        let restored = protected.restore(echoed)
        #expect(restored.clientFollowUp == input)
    }

    @Test("Summary tasks still redact secrets irreversibly")
    func summary_keepsIrreversibleRedaction() {
        let protected = SensitiveDataProtector.protect(
            transcript: "use api_key=supersecretvalue",
            title: "Meeting",
            task: .standard,
            detectNamedEntities: false
        )
        #expect(protected.transcript.contains("[[REDACTED_SECRET]]"))
        #expect(protected.report.redactedOccurrences == 1)
    }

    @Test("The transcript polisher drops a chunk that still carries a placeholder")
    func polisher_rejectsSurvivingPlaceholder() {
        let lines = ["привет как дела"]
        let c = TranscriptPolisher.Chunk(ids: lines.map { _ in UUID() }, lines: lines)
        let reply = "1. Привет [[DAISY_PERSON_001]], как дела?"
        #expect(TranscriptPolisher.validate(reply: reply, chunk: c) == nil)
    }
}

// MARK: - Transcript presence (P0: audio purged from sessions with no transcript)

@Suite("A transcript shell is not a transcript")
struct TranscriptPresenceTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Header plus heading with nothing under it counts as no content")
    func shellOnly_isNotContent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Exactly what MarkdownExporter writes for a zero-segment session.
        let shell = """
        ---
        title: "Sync"
        started: 2026-09-01T10:00:00Z
        ---
        # Sync

        > recorded 1 Sep 2026 · 12:00

        ## Transcript

        """
        try shell.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        #expect(!RecordingSession.transcriptHasContent(in: dir))
    }

    @Test("One line of speech under the heading counts")
    func speechLine_isContent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = """
        ---
        title: "Sync"
        ---
        # Sync

        ## Transcript

        **[00:00:03 · Me]** привет
        """
        try text.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        #expect(RecordingSession.transcriptHasContent(in: dir))
    }

    @Test("A missing file errs on the side of keeping the audio")
    func missingFile_isNotContent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!RecordingSession.transcriptHasContent(in: dir))
    }

    @Test("A file without the heading falls back to body presence")
    func unknownShape_usesBody() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\ntitle: x\n---\n\nsome words\n".write(
            to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8
        )
        #expect(RecordingSession.transcriptHasContent(in: dir))
        try "---\ntitle: x\n---\n\n".write(
            to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8
        )
        #expect(!RecordingSession.transcriptHasContent(in: dir))
    }
}

// MARK: - Persisted user fields (P1: post-stop re-render reverting edits)

@Suite("Post-stop re-render reads the person's edits back")
struct PersistedUserFieldsTests {

    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-fm-\(UUID().uuidString).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Title, folder, tag and kind come back exactly as written")
    func fields_roundTrip() throws {
        let url = try write("""
        ---
        title: "Q3: budget \\"final\\""
        daisy_folder: clients
        daisy_kind: note
        daisy_tag: "urgent"
        daisy_speaker_map: {A: "Алексей"}
        ---
        body
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = RecordingSession.persistedUserFields(at: url)
        #expect(f.title == "Q3: budget \"final\"")
        #expect(f.folderSlug == "clients")
        #expect(f.kind == "note")
        #expect(f.tag == "urgent")
        #expect(f.speakerMap["A"] == "Алексей")
    }

    @Test("An absent key reads as nil, an emptied tag reads as empty")
    func fields_absentVersusEmpty() throws {
        let url = try write("""
        ---
        title: "x"
        daisy_tag: ""
        ---
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = RecordingSession.persistedUserFields(at: url)
        #expect(f.folderSlug == nil)
        #expect(f.kind == nil)
        #expect(f.tag == "")
    }

    @Test("A file with no frontmatter yields nothing")
    func fields_noFrontmatter() throws {
        let url = try write("# just a body\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let f = RecordingSession.persistedUserFields(at: url)
        #expect(f.title == nil)
        #expect(f.speakerMap.isEmpty)
    }
}

// MARK: - Archive reader holes (P1: silent skips shifting timestamps)

@Suite("An unreadable archive part is counted, not swallowed")
struct ArchiveBlockReaderHoleTests {

    @Test("A missing part lands in skippedParts")
    func missingPart_isReported() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).caf")
        let reader = ArchiveBlockReader(urls: [missing])
        #expect(reader.nextBlock() == nil)
        #expect(reader.skippedParts == [missing])
    }

    @Test("A zero-byte part is reported too")
    func emptyPart_isReported() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).caf")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = ArchiveBlockReader(urls: [url])
        #expect(reader.nextBlock() == nil)
        #expect(reader.skippedParts.count == 1)
    }
}
