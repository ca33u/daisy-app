//
//  SessionRoundTripTests.swift
//  DaisyCoreTests
//
//  The N-1 DoD: a session assembled on the phone → rendered → read back
//  by the Mac's own parser (copied verbatim into `SessionDocument`) with
//  every field intact; keys in §3.1 order; hidden staging folders
//  invisible to the scanner; §6 classification for every shape.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Session contract round trip")
struct SessionRoundTripTests {

    // MARK: - Fixtures

    private func makeBase() throws -> SessionsBase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisycore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SessionsBase(base: url)
    }

    private func write(_ text: String, as name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func writeBlob(bytes: Int, as name: String, in dir: URL) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    private var started: Date { Date(timeIntervalSince1970: 1_788_840_000) } // 2026-09-08T04:00:00Z
    private var sampleSegments: [TranscriptSegment] {
        [
            TranscriptSegment(startedAt: started, text: "Hello, this is a test.", startSec: 7.2, endSec: 9.0),
            TranscriptSegment(startedAt: started, text: "  ", startSec: 10, endSec: 11),
            TranscriptSegment(startedAt: started, text: "Второй сегмент по-русски.", startSec: 75.6, endSec: 80),
        ]
    }

    // MARK: - Frontmatter

    @Test func phoneProfileRoundTripsThroughMacParser() throws {
        let fm = SessionFrontmatter.phoneRecording(
            title: "Meeting with \"Acme\", Inc.",
            started: started,
            duration: 61.98,
            micBytes: 1_234_567
        )
        let text = TranscriptDocument.render(frontmatter: fm, segments: sampleSegments, userDisplayName: "Egor")

        let parsed = SessionDocument.parseFrontmatter(in: text)
        #expect(parsed.title == "Meeting with \\\"Acme\\\", Inc.")   // Mac parser only strips the outer quotes
        #expect(SessionDocument.yamlUnquote("\"" + parsed.title! + "\"") == "Meeting with \"Acme\", Inc.")
        #expect(parsed["type"] == "meeting-transcript")
        #expect(parsed["source"] == "Daisy")
        #expect(parsed.locale == "auto")
        #expect(parsed.started == "2026-09-08T04:00:00Z")
        #expect(parsed.durationSec == 61)                     // truncated, not 62
        #expect(parsed.folder == "inbox")
        #expect(parsed.kind == "recording")
        #expect(parsed["daisy_origin"] == "iphone")
        #expect(parsed.speakerMap == [:])
        #expect(parsed.systemAudioStatus == "off")
        #expect(parsed.micAudioStatus == "captured (1234567 B)")
        #expect(parsed["tags"] == "[meeting, transcript, daisy]")
        #expect(parsed.tag == nil)

        let back = try #require(SessionFrontmatter.parse(text))
        #expect(back.started == started)
        #expect(back.durationSec == 61)
        #expect(back.micAudioStatus == .captured(bytes: 1_234_567))
        #expect(back.systemAudioStatus == .off)
        #expect(back.origin == "iphone")
        #expect(back.kind == .recording)
        #expect(back.tags == ["meeting", "transcript", "daisy"])
        #expect(back.audioParts.isEmpty)
    }

    @Test func keysAreWrittenInContractOrder() {
        var fm = SessionFrontmatter.phoneRecording(title: "T", started: started, duration: 10, micBytes: 10)
        fm.detectedLocale = "ru"
        fm.tag = "Acme"
        fm.speakerMap = ["A": "Alex"]
        fm.audioParts = ["microphone.caf", "microphone.part2.caf"]
        fm.micOnlyCause = "permission"
        fm.transcriptionModel = "large-v3-v20240930_626MB"
        fm.transcriptionLanguage = "auto"
        let parsed = SessionDocument.parseFrontmatter(in: fm.render() + "\n\n# T\n")
        #expect(parsed.keyOrder == [
            "title", "type", "source", "locale", "detected_locale", "started",
            "duration_sec", "daisy_folder", "daisy_kind", "daisy_origin", "daisy_tag",
            "daisy_transcription_model", "daisy_transcription_language",
            "daisy_speaker_map", "daisy_audio_parts",
            "daisy_system_audio_status", "daisy_mic_audio_status", "daisy_mic_only", "tags",
        ])
        #expect(parsed.speakerMap == ["A": "Alex"])
        #expect(parsed["daisy_audio_parts"] == "[\"microphone.caf\", \"microphone.part2.caf\"]")
        // backlog 6 F-1: the Mac's own keys, quoted the Mac's way, read back.
        #expect(parsed["daisy_transcription_model"] == "large-v3-v20240930_626MB")
        #expect(fm.render().contains("daisy_transcription_model: \"large-v3-v20240930_626MB\""))
        let back = SessionFrontmatter.parse(fm.render() + "\n\n# T\n")
        #expect(back?.transcriptionModel == "large-v3-v20240930_626MB")
        #expect(back?.transcriptionLanguage == "auto")
    }

    @Test func speakerMapReaderStripsQuotedKeysToo() {
        // The Mac has a writer that emits quoted keys (§3.2). We must read both.
        #expect(SessionDocument.parseYAMLDict("{\"A\": \"Alex\", B: \"Maria\"}") == ["A": "Alex", "B": "Maria"])
        #expect(SessionDocument.yamlInlineDict(["B": "Maria", "A": "Alex"]) == "{A: \"Alex\", B: \"Maria\"}")
        // No escaping exists for commas — replaced.
        #expect(SessionDocument.yamlInlineDict(["A": "Smith, John"]) == "{A: \"Smith  John\"}")
    }

    @Test func upsertReplacesFirstMatchingLineOrInsertsBeforeClose() {
        let fm = SessionFrontmatter.phoneRecording(title: "T", started: started, duration: 1, micBytes: 1)
        let text = fm.render() + "\n\n# T\n"
        let retitled = SessionDocument.upsertFrontmatter(in: text, key: "title", value: "\"New\"")
        #expect(SessionDocument.parseFrontmatter(in: retitled).title == "New")
        let tagged = SessionDocument.upsertFrontmatter(in: retitled, key: "daisy_tag", value: "\"Acme\"")
        let parsed = SessionDocument.parseFrontmatter(in: tagged)
        #expect(parsed.tag == "Acme")
        #expect(parsed.keyOrder.last == "daisy_tag")     // inserted before the closing ---
        #expect(parsed.body.contains("# T"))
        // No frontmatter → a fresh block is prepended.
        #expect(SessionDocument.upsertFrontmatter(in: "# bare", key: "title", value: "\"X\"").hasPrefix("---\ntitle: \"X\"\n---\n"))
    }

    // MARK: - Body

    @Test func bodyHasOnlyTranscriptSectionWithMacSeparator() {
        let fm = SessionFrontmatter.phoneRecording(title: "T", started: started, duration: 90, micBytes: 1)
        let text = TranscriptDocument.render(frontmatter: fm, segments: sampleSegments, userDisplayName: "Egor")
        let body = SessionDocument.parseFrontmatter(in: text).body
        #expect(body.contains("\n# T\n"))
        #expect(body.contains("\n## Transcript\n"))
        #expect(!body.contains("## Summary"))
        #expect(!body.contains("## Screenshots"))
        #expect(!body.contains("## Marked moments"))
        #expect(body.contains("**[0:07 · Egor]** Hello, this is a test."))
        #expect(body.contains("**[1:16 · Egor]** Второй сегмент по-русски."))
        #expect(!body.contains("**[0:10"))                     // blank segment dropped
        #expect(TranscriptDocument.hasTranscriptContent(text))
        // "Me" when no display name.
        let anon = TranscriptDocument.render(frontmatter: fm, segments: sampleSegments, userDisplayName: nil)
        #expect(anon.contains("· Me]**"))
        #expect(TranscriptDocument.formatDuration(3_725) == "1:02:05")
    }

    // MARK: - Session ID

    @Test func sessionIDMatchesMacShapeAndParsesBothForms() {
        let id = SessionID.make(for: started)
        #expect(id == "2026-09-08T04-00-00Z")
        #expect(SessionID.parse(id) == started)
        #expect(SessionID.parse("2026-09-08T04-00-00Z-2") == started)
        #expect(SessionID.parse("2026-05-16T22-30-00+08-00") == ISO8601DateFormatter().date(from: "2026-05-16T22:30:00+08:00"))
        #expect(SessionID.parse("My folder") == nil)
    }

    @Test func sessionIDCollisionGetsSuffix() throws {
        let base = try makeBase()
        let sessions = try base.ensureSessionsDirectory()
        try FileManager.default.createDirectory(at: sessions.appendingPathComponent("2026-09-08T04-00-00Z"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions.appendingPathComponent("2026-09-08T04-00-00Z-2"), withIntermediateDirectories: true)
        #expect(SessionID.unique(for: started, in: sessions) == "2026-09-08T04-00-00Z-3")
        // A staging folder reserving the id counts as taken too.
        let draft = try SessionWriter.begin(startedAt: started, in: base)
        #expect(draft.id == "2026-09-08T04-00-00Z-3")
        let second = try SessionWriter.begin(startedAt: started, in: base)
        #expect(second.id == "2026-09-08T04-00-00Z-4")
    }

    // MARK: - Writer + classifier

    @Test func stagingIsHiddenFromScanAndPublishMovesItIntoPlace() throws {
        let base = try makeBase()
        let draft = try SessionWriter.begin(startedAt: started, in: base)
        #expect(draft.stagingURL.lastPathComponent.hasPrefix(".daisy-recording-"))
        try writeBlob(bytes: 300 * 1024, as: "microphone.caf", in: draft.stagingURL)
        try SessionWriter.writeRecordingMarker(draft)

        // Nothing visible while recording; a stray `.tmp` folder is ignored too.
        try FileManager.default.createDirectory(at: base.sessionsDirectory.appendingPathComponent(".something.tmp"), withIntermediateDirectories: true)
        #expect(SessionClassifier.scan(base: base).isEmpty)

        let fm = SessionFrontmatter.phoneRecording(title: "T", started: started, duration: 5, micBytes: 300 * 1024)
        let text = TranscriptDocument.render(frontmatter: fm, segments: sampleSegments, userDisplayName: nil)
        let published = try SessionWriter.publish(draft, transcript: text)
        #expect(published.lastPathComponent == draft.id)
        #expect(!FileManager.default.fileExists(atPath: draft.stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: published.appendingPathComponent(".recording").path))

        let rows = SessionClassifier.scan(base: base)
        #expect(rows.count == 1)
        #expect(rows[0].state == .valid)
        #expect(rows[0].title == "T")
        #expect(rows[0].startedAt == started)
        #expect(rows[0].durationSec == 5)
        #expect(rows[0].origin == "iphone")
        #expect(rows[0].hasTranscript && rows[0].hasAudio)
    }

    @Test func publishRefusesToOverwriteAnExistingTranscript() throws {
        let base = try makeBase()
        let draft = try SessionWriter.begin(startedAt: started, in: base)
        try write("---\ntitle: \"x\"\n---\n", as: "transcript.md", in: draft.stagingURL)
        #expect(throws: SessionWriterError.transcriptAlreadyExists) {
            try SessionWriter.publish(draft, transcript: "---\ntitle: \"y\"\n---\n")
        }
        // Audio-only publish keeps the marker for the finishing pass.
        let d2 = try SessionWriter.begin(startedAt: started.addingTimeInterval(1), in: base)
        try writeBlob(bytes: 1024, as: "microphone.caf", in: d2.stagingURL)
        try SessionWriter.writeRecordingMarker(d2)
        let url = try SessionWriter.publishAudioOnly(d2)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(".recording").path))
        let row = try #require(SessionClassifier.summarize(directory: url))
        #expect(row.state == .interrupted)        // marker + audio, no transcript
        #expect(row.startedAt == started.addingTimeInterval(1))   // from the marker
        // Finishing pass: transcript lands, marker goes.
        try SessionWriter.finish(directory: url, transcript: "---\ntitle: \"done\"\nstarted: 2026-09-08T04:00:01Z\n---\n\n# done\n")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(".recording").path))
        #expect(SessionClassifier.classify(directory: url) == .valid)
    }

    @Test func classifierShapes() throws {
        let base = try makeBase()
        let sessions = try base.ensureSessionsDirectory()
        func dir(_ name: String) throws -> URL {
            let u = sessions.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        // Empty folder — valid (visible, nothing to recover).
        #expect(SessionClassifier.classify(directory: try dir("empty")) == .valid)
        // Small audio, no marker — valid (below 256 KB).
        let small = try dir("small"); try writeBlob(bytes: 100 * 1024, as: "microphone.caf", in: small)
        #expect(SessionClassifier.classify(directory: small) == .valid)
        // Big audio, no marker — interrupted.
        let big = try dir("big"); try writeBlob(bytes: 300 * 1024, as: "microphone.caf", in: big)
        #expect(SessionClassifier.classify(directory: big) == .interrupted)
        // Big audio + import.json — valid (an import awaiting transcription).
        let imported = try dir("imported"); try writeBlob(bytes: 300 * 1024, as: "system_audio.m4a", in: imported)
        try write("{}", as: "import.json", in: imported)
        #expect(SessionClassifier.classify(directory: imported) == .valid)
        // Audio + empty transcript with no title/started — interrupted.
        let husk = try dir("husk"); try writeBlob(bytes: 300 * 1024, as: "microphone.caf", in: husk)
        try write("---\nlocale: auto\n---\n\n", as: "transcript.md", in: husk)
        #expect(SessionClassifier.classify(directory: husk) == .interrupted)
        // Audio + recovered-profile transcript (title only) — valid.
        let recovered = try dir("recovered"); try writeBlob(bytes: 300 * 1024, as: "microphone.caf", in: recovered)
        try write("---\ntitle: \"Recovered\"\ndaisy_recovered: true\n---\n", as: "transcript.md", in: recovered)
        #expect(SessionClassifier.classify(directory: recovered) == .valid)
        // Transcript only (audio swept) — valid.
        let textOnly = try dir("textonly")
        try write("---\ntitle: \"T\"\nstarted: 2026-09-08T04:00:00Z\n---\n\n# T\n", as: "transcript.md", in: textOnly)
        #expect(SessionClassifier.classify(directory: textOnly) == .valid)
        // Hidden entries and loose files are not sessions.
        try write("x", as: ".daisy-audio-abc.m4a", in: sessions)
        try write("x", as: "notes.txt", in: sessions)
        let ids = Set(SessionClassifier.scan(base: base).map(\.id))
        #expect(ids == ["empty", "small", "big", "imported", "husk", "recovered", "textonly"])
        // Unreadable path — never modified, never listed.
        #expect(SessionClassifier.classify(directory: sessions.appendingPathComponent("does-not-exist")) == .unreadable)
    }

    // MARK: - B-1: subtitle must agree with the truncated duration_sec

    @Test func subtitleMatchesTruncatedDurationSecNeverRoundsUp() {
        // 41.98s truncates to duration_sec: 41 — the subtitle must say
        // "0:41", not "0:42" (bug found in the night-1 report: the body
        // used to format the RAW float, which rounds up).
        let fm = SessionFrontmatter.phoneRecording(title: "T", started: started, duration: 41.98, micBytes: 1)
        let text = TranscriptDocument.render(frontmatter: fm, segments: [], userDisplayName: nil)
        #expect(SessionDocument.parseFrontmatter(in: text).durationSec == 41)
        #expect(text.contains("· 0:41"))
        #expect(!text.contains("· 0:42"))
    }

    // MARK: - B-1: startup recovery of a crashed staging folder

    @Test func crashedStagingFolderIsPublishedAndClassifiedInterruptedOnSweep() throws {
        let base = try makeBase()
        let sessions = try base.ensureSessionsDirectory()
        let id = "2026-09-19T08-00-00Z"
        let staging = sessions.appendingPathComponent(SessionWriter.stagingPrefix + id, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeBlob(bytes: 300 * 1024, as: "microphone.caf", in: staging)
        try write("2026-09-19T08:00:00Z", as: ".recording", in: staging)

        // A live recording's own staging folder must be left alone.
        let liveID = "2026-09-19T09-00-00Z"
        let liveStaging = sessions.appendingPathComponent(SessionWriter.stagingPrefix + liveID, isDirectory: true)
        try FileManager.default.createDirectory(at: liveStaging, withIntermediateDirectories: true)
        let liveDraft = DraftSession(id: liveID, startedAt: started, stagingURL: liveStaging,
                                      publishedURL: sessions.appendingPathComponent(liveID, isDirectory: true))

        SessionWriter.sweepStaging(in: base, keeping: liveDraft)

        let published = sessions.appendingPathComponent(id, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: published.path))
        #expect(SessionClassifier.classify(directory: published) == .interrupted)
        // The live one is untouched — still staged, invisible to a scan.
        #expect(FileManager.default.fileExists(atPath: liveStaging.path))
        #expect(SessionClassifier.scan(base: base).map(\.id) == [id])

        // The finishing pass a real launch would run next: recovery
        // writes a transcript and the folder becomes valid (§6.1).
        try SessionWriter.finish(directory: published, transcript: "---\ntitle: \"Recovered\"\nstarted: 2026-09-19T08:00:00Z\n---\n\n# Recovered\n")
        #expect(SessionClassifier.classify(directory: published) == .valid)
    }

    @Test func recoveryProfileTruncatesDurationAndWritesMinimalKeys() {
        final class NoEngine: Transcribing {
            var isReady: Bool { false }
            func transcribe(samples: [Float]) async throws -> [TranscriptSegment] { [] }
        }
        let recovery = InterruptedRecordingRecovery(engine: NoEngine(), decoder: { _ in nil })
        let md = recovery.renderMarkdown(startDate: started, durationSec: 59.9, mic: "hello", system: nil)
        let parsed = SessionDocument.parseFrontmatter(in: md)
        #expect(parsed.keyOrder == ["title", "started", "daisy_recovered", "daisy_kind", "duration_sec"])
        #expect(parsed.durationSec == 59)
        #expect(parsed["daisy_recovered"] == "true")
        #expect(md.contains("## Your side"))
        #expect(!md.contains("## Transcript"))     // §3.5: deliberately no such heading
        recovery.defaultFolderSlug = "work"
        #expect(SessionDocument.parseFrontmatter(in: recovery.renderMarkdown(startDate: started, durationSec: 1, mic: nil, system: nil)).folder == "work")
    }
}

/// §3.6, backlog 14: the microphone is the room for every recorder but
/// the Mac, and a reader that meets a value it has never heard of must
/// fail towards "we don't know who spoke".
@Suite("Which microphone is the room")
struct SessionOriginTests {
    @Test func aMacSessionIsTheOnlyOneWhoseMicrophoneIsItsOwner() {
        #expect(!SessionOrigin.isRoomMicrophone(nil))
        #expect(!SessionOrigin.isRoomMicrophone(""))
        #expect(!SessionOrigin.isRoomMicrophone("mac"))
    }

    @Test func everyRecorderWeShipRecordsTheRoom() {
        for origin in [SessionOrigin.iphone, SessionOrigin.watch, SessionOrigin.importedFile] {
            #expect(SessionOrigin.isRoomMicrophone(origin))
        }
    }

    /// The whole point of writing the rule this way round: a future
    /// recorder must not make an old reader stamp the owner's name on
    /// a stranger's words.
    @Test func anUnknownRecorderIsTreatedAsARoom() {
        #expect(SessionOrigin.isRoomMicrophone("ipad-2029"))
    }

    /// Audio that has to travel is a different question: only a
    /// recording this family of devices made is the only copy.
    @Test func onlyOurOwnRecordingsAreTheOnlyCopy() {
        #expect(SessionOrigin.isOwnRecording(SessionOrigin.iphone))
        #expect(SessionOrigin.isOwnRecording(SessionOrigin.watch))
        #expect(!SessionOrigin.isOwnRecording(SessionOrigin.importedFile))
        #expect(!SessionOrigin.isOwnRecording(nil))
        #expect(!SessionOrigin.isOwnRecording("ipad-2029"))
    }

    @Test func anImportedFileSaysSoInTheFrontmatter() {
        let fm = SessionFrontmatter.phoneRecording(
            title: "Imported", started: Date(), duration: 60, micBytes: 0,
            origin: SessionOrigin.importedFile)
        #expect(fm.render().contains("daisy_origin: import"))
        let phone = SessionFrontmatter.phoneRecording(
            title: "Recorded", started: Date(), duration: 60, micBytes: 100)
        #expect(phone.render().contains("daisy_origin: iphone"))
    }
}
